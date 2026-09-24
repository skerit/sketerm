//! The semantic layer, browser-process half, split out of `cefhost.zig`:
//! sending commands to `semantic.js`, correlating its replies, and the
//! sem_* request handlers (snapshot, act, expand, query, eval, read).
//! The `Host` methods are free functions taking `*Host`, re-exported from
//! `Host` under their old names. The render-process half stays in
//! `cefhost.zig` (see "SEMANTIC LAYER PROCESS FLOW" there).

const std = @import("std");
const cef = @import("cef");
const nowMs = @import("../../util/clock.zig").nowMs;
const proto = @import("../protocol.zig");
const semantic = @import("../semantic.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const Pending = host_mod.Pending;
const View = host_mod.View;
const discarded_msg = host_mod.discarded_msg;
const jsonStr = host_mod.jsonStr;
const max_expand = host_mod.max_expand;
const release = host_mod.release;
const runJs = host_mod.runJs;
const secretEql = host_mod.secretEql;
const semantic_request_timeout_ms = host_mod.semantic_request_timeout_ms;
const sendClick = host_mod.sendClick;
const sendMove = host_mod.sendMove;
const setFocus = host_mod.setFocus;
const stale_reader_msg = host_mod.stale_reader_msg;
const typeText = host_mod.typeText;
const viewPoint = host_mod.viewPoint;
const withHostArgs = host_mod.withHostArgs;

// -- semantic layer ------------------------------------------------

/// Hand one JSON command to the view's main frame, as a call into
/// the script's command entry point (`window[<slot>]`).
///
/// `execute_java_script` works straight from the browser process
/// (CEF routes it to the frame's renderer), which is why the
/// command direction needs no process message and no V8 call at
/// all — only the REPLY direction does.
pub fn sendScript(self: *Host, v: *View, json: []const u8) void {
    if (!host_mod.sem_secret.ok) return;
    const b = v.browser orelse return;
    const gf = b.get_main_frame orelse return;
    const frame: *cef.cef_frame_t = gf(b) orelse return;
    defer release(&frame.base);
    self.sendScriptToFrameGen(frame, json, v.sem_nav.generation);
}

/// Hand a command to ONE frame, main or not.
pub fn sendScriptToFrame(self: *Host, frame: *cef.cef_frame_t, json: []const u8) void {
    self.sendScriptToFrameGen(frame, json, 0);
}

pub fn sendScriptToFrameGen(self: *Host, frame: *cef.cef_frame_t, json: []const u8, nav_gen: u32) void {
    if (!host_mod.sem_secret.ok) return;
    var code: std.Io.Writer.Allocating = .init(self.gpa);
    defer code.deinit();
    const slot: []const u8 = &host_mod.sem_secret.slot;
    code.writer.print("window[\"{s}\"]&&window[\"{s}\"](", .{ slot, slot }) catch return;
    jsonStr(&code.writer, json) catch return;
    code.writer.print(",{d})", .{nav_gen}) catch return;
    runJs(frame, code.written());
}

/// Hand a command to every frame of a view.
///
/// Frame identifiers are opaque STRINGS in this CEF, enumerated into
/// a `cef_string_list_t`; `get_frame_by_identifier` then takes a
/// reference we must release. Used for messages that address a TAB
/// rather than a document, where a content script in an ad iframe is
/// as much a recipient as the top one.
pub fn sendScriptAllFrames(self: *Host, v: *View, json: []const u8) void {
    if (!host_mod.sem_secret.ok) return;
    const b = v.browser orelse return;
    const gfi = b.get_frame_identifiers orelse {
        self.sendScript(v, json);
        return;
    };
    const list = cef.cef_string_list_alloc() orelse {
        self.sendScript(v, json);
        return;
    };
    defer cef.cef_string_list_free(list);
    gfi(b, list);
    const n = cef.cef_string_list_size(list);
    if (n == 0) {
        self.sendScript(v, json);
        return;
    }
    const byid = b.get_frame_by_identifier orelse return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ident = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&ident);
        if (cef.cef_string_list_value(list, i, &ident) == 0) continue;
        const frame: *cef.cef_frame_t = byid(b, &ident) orelse continue;
        defer release(&frame.base);
        self.sendScriptToFrame(frame, json);
    }
}

/// Queue a request; the oldest is dropped when a page stops
/// answering, so a dead script cannot grow the list without bound.
pub fn pushPending(self: *Host, v: *View, p: Pending) !u32 {
    if (v.pending.items.len >= 32) {
        const old = v.pending.orderedRemove(0);
        self.failPending(v, old, "semantic request queue overflowed");
    }
    var stamped = p;
    if (stamped.client_request == 0) stamped.client_request = self.active_sem_request;
    stamped.nav_gen = v.sem_nav.generation;
    stamped.deadline_ms = nowMs() + semantic_request_timeout_ms;
    try v.pending.append(self.gpa, stamped);
    return p.req;
}

pub fn takePending(self: *Host, v: *View, req: u32) ?Pending {
    _ = self;
    if (req == 0) return null;
    for (v.pending.items, 0..) |p, i| {
        if (p.req == req) return v.pending.orderedRemove(i);
    }
    return null;
}

pub fn pendingFor(self: *Host, v: *View, req: u32) ?*Pending {
    _ = self;
    if (req == 0) return null;
    for (v.pending.items) |*p| {
        if (p.req == req) return p;
    }
    return null;
}

pub fn nextReq(v: *View) u32 {
    const r = v.sem_next_req;
    v.sem_next_req +%= 1;
    if (v.sem_next_req == 0) v.sem_next_req = 1;
    return r;
}

pub fn freePending(self: *Host, p: Pending) void {
    if (p.arg.len != 0) self.gpa.free(p.arg);
}

pub fn failPending(self: *Host, v: *View, p: Pending, msg: []const u8) void {
    defer self.freePending(p);
    const old_request = self.active_sem_request;
    self.active_sem_request = p.client_request;
    defer self.active_sem_request = old_request;
    switch (p.kind) {
        .snapshot => self.post(proto.SemSnapshot{
            .view = v.id,
            .doc_gen = 0,
            .rev = 0,
            .kind = @intFromEnum(proto.SnapKind.full),
            .payload = .{ .s = msg },
        }),
        .hints, .query => self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = msg } }),
        .review => self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = "{\"pending\":true}" } }),
        .click, .hover, .act, .set_value, .commit, .guarded_act, .choose_pick, .choose_done => self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = msg }),
        .expand => self.post(proto.SemExpandResult{ .view = v.id, .id = p.sid, .off = p.off, .text = msg }),
        .read => self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = msg } }),
        .read_ids => self.post(proto.SemReadIdsResult{
            .view = v.id,
            .doc_gen = 0,
            .rev = 0,
            .markdown = .{ .s = msg },
            .entities = &.{},
        }),
        // The eval lane answers in JSON, so the reason has to be
        // encoded rather than passed through — but it IS the same
        // reason every other kind reports. A bare "semantic request
        // expired" for a renderer crash, a stopped load and a
        // 120s-silent page alike told a caller nothing about which
        // of the three had happened, or whether retrying helps.
        .eval => {
            var buf: [512]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            const text: []const u8 = blk: {
                w.writeAll("{\"error\":") catch break :blk "{\"error\":\"semantic request expired\"}";
                jsonStr(&w, msg) catch break :blk "{\"error\":\"semantic request expired\"}";
                w.writeByte('}') catch break :blk "{\"error\":\"semantic request expired\"}";
                break :blk w.buffered();
            };
            self.post(proto.SemEvalResult{ .view = v.id, .ok = 0, .json = .{ .s = text } });
        },
    }
}

/// Navigation invalidates every command sent to the old V8 context.
/// Reads and snapshots are safe to reissue against the new page;
/// actions are not and are answered explicitly instead of hanging.
///
/// This is the ONE place a main-frame document replacement passes
/// through: the client-driven paths (`navigate`, `navAction`) call it
/// before asking the engine, and `onLoadStart` calls it for every load
/// they did not arm. So it is also where a content script's
/// `runtime.connect` Ports die: their JS `Port` objects go with the
/// document, and a Port nobody can reach again would otherwise sit in
/// the table for the life of the helper, still messageable by its
/// background page.
pub fn semanticNavigationStarted(self: *Host, v: *View) void {
    v.sem_nav.start(false);
    v.sem_context_doc = 0;
    v.sem_observing = false;
    self.portsAbandonView(v.id);
    for (v.pending.items) |*p| {
        switch (p.kind) {
            .snapshot, .hints, .query, .read, .read_ids => {
                p.rearm = true;
                p.nav_gen = v.sem_nav.generation;
                p.req = nextReq(v);
                p.deadline_ms = nowMs() + semantic_request_timeout_ms;
            },
            else => {},
        }
    }
    var i: usize = 0;
    while (i < v.pending.items.len) {
        if (v.pending.items[i].rearm) {
            i += 1;
            continue;
        }
        const p = v.pending.orderedRemove(i);
        self.failPending(v, p, if (p.guarded or p.kind == .guarded_act) stale_reader_msg else "semantic action interrupted by navigation");
    }
}

/// Bound script operations even when a renderer remains alive but
/// never replies. This releases owned args and unblocks its client.
pub fn semanticPump(self: *Host, now: i64) void {
    for (self.views.items) |v| {
        var i: usize = 0;
        while (i < v.pending.items.len) {
            if (v.pending.items[i].deadline_ms > now) {
                i += 1;
                continue;
            }
            const p = v.pending.orderedRemove(i);
            var buf: [160]u8 = undefined;
            self.failPending(v, p, std.fmt.bufPrint(
                &buf,
                "the page did not answer this request within {d}s (a blocked main thread, or script that never settled)",
                .{@divTrunc(semantic_request_timeout_ms, 1000)},
            ) catch "semantic request expired before the page replied");
        }
    }
    // Same rule for every parked extension Promise: a recipient
    // that never answers (bridge not bootstrapped, listener silent,
    // a GUI that dropped the popup acknowledgement) must not park
    // the caller forever.
    var i: usize = 0;
    while (i < self.webext_replies.items.len) {
        if (self.webext_replies.items[i].deadline_ms > now) {
            i += 1;
            continue;
        }
        const rec = self.webext_replies.orderedRemove(i);
        self.failReply(rec, rec.kind.expired());
    }
}

test "semantic navigation reissues reads with fresh ids and rejects guarded actions" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.webext.deinit();
    const v = try gpa.create(View);
    defer gpa.destroy(v);
    v.* = .{
        .id = 7,
        .w = 1,
        .h = 1,
        .scale_x1000 = 1000,
        .pw = 1,
        .ph = 1,
        .sem = semantic.View.init(gpa),
    };
    defer v.sem.deinit();
    defer v.pending.deinit(gpa);
    try host.views.append(gpa, v);
    defer host.views.deinit(gpa);

    const arg = try gpa.dupe(u8, "typed");
    _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .read });
    _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .read_ids });
    _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .guarded_act, .sid = 44, .guarded = true, .arg = arg });
    const old_read = v.pending.items[0].req;
    const old_rich = v.pending.items[1].req;

    host.semanticNavigationStarted(v);
    try std.testing.expectEqual(@as(usize, 2), v.pending.items.len);
    try std.testing.expect(v.pending.items[0].rearm and v.pending.items[0].req != old_read);
    try std.testing.expect(v.pending.items[1].rearm and v.pending.items[1].req != old_rich);
    try std.testing.expectEqual(@as(usize, 1), out.pending());
    const frame = proto.Reader.init(out.front().?.bytes);
    var reader = frame;
    const failed = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.sem_act_result, failed.tag);
    try std.testing.expectEqual(@as(u8, 0), (try proto.decode(proto.SemActResult, failed.payload)).ok);

    const new_read = v.pending.items[0].req;
    try std.testing.expect(host.takePending(v, old_read) == null);
    try std.testing.expect(host.takePending(v, new_read) != null);
    while (v.pending.pop()) |p| host.freePending(p);
}

test "semantic result envelopes keep the client request id" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.webext.deinit();
    host.active_sem_request = 77;
    host.post(proto.SemActResult{ .view = 4, .id = 9, .ok = 1, .msg = "ok" });
    var reader = proto.Reader.init(out.front().?.bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.sem_result, frame.tag);
    const result = try proto.decode(proto.SemResult, frame.payload);
    try std.testing.expectEqual(@as(u32, 77), result.request);
    try std.testing.expectEqual(@intFromEnum(proto.Tag.sem_act_result), result.kind);
    const inner = try proto.decode(proto.SemActResult, result.payload.s);
    try std.testing.expectEqual(@as(u32, 9), inner.id);
    try std.testing.expectEqualStrings("ok", inner.msg);
}

test "semantic stop exits loading and frees rearmed requests" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.webext.deinit();
    var v = View{
        .id = 7,
        .w = 1,
        .h = 1,
        .scale_x1000 = 1000,
        .pw = 1,
        .ph = 1,
        .sem = semantic.View.init(gpa),
        .sem_nav = .{ .loading = true, .waiting_load_start = true },
    };
    defer v.pending.deinit(gpa);
    defer v.sem.deinit();
    const arg = try gpa.dupe(u8, "owned");
    try v.pending.append(gpa, .{ .req = 1, .kind = .read_ids, .client_request = 15, .rearm = true, .arg = arg });
    host.semanticStopped(&v);
    try std.testing.expect(!v.sem_nav.loading);
    try std.testing.expect(!v.sem_nav.waiting_load_start);
    try std.testing.expectEqual(@as(usize, 0), v.pending.items.len);
    var reader = proto.Reader.init(out.front().?.bytes);
    const result = try proto.decode(proto.SemResult, (try reader.next()).?.payload);
    try std.testing.expectEqual(@as(u32, 15), result.request);
    try std.testing.expectEqual(@intFromEnum(proto.Tag.sem_read_ids_result), result.kind);
}

pub fn semSnapshot(self: *Host, req: proto.SemSnapshotReq) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        // A discarded view has no page to walk, and a request that
        // simply went unanswered would hang every client that waits
        // for its reply frame. Answer, and say what to do about it.
        self.post(proto.SemSnapshot{
            .view = v.id,
            .doc_gen = 0,
            .rev = 0,
            .kind = @intFromEnum(proto.SnapKind.full),
            .payload = .{ .s = discarded_msg },
        });
        return;
    }
    v.sem_detail = req.detail;
    v.sem_want_observer = true;
    const rid = try self.pushPending(v, .{
        .req = nextReq(v),
        .kind = .snapshot,
        .mode = req.mode,
        .detail = req.detail,
        .scope = req.scope,
        .rearm = v.sem_nav.loading,
    });
    if (v.sem_nav.loading) return;
    var buf: [96]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &buf,
        "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
        .{ rid, req.detail },
    ) catch return;
    self.sendScript(v, cmd);
    if (!v.sem_observing) {
        v.sem_observing = true;
        self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
    }
}

/// Dispatch one request-id envelope through the existing semantic
/// handlers. The inner payload is byte-for-byte the legacy frame's
/// payload; only the outer tags are append-only additions.
/// A view id the dispatching CLIENT encoded inside an opaque
/// payload — where the socket edge could not translate it. Maps it
/// into the engine's namespace through the router; identity without
/// one, or outside a dispatch.
pub fn mapDispatchView(self: *Host, id: u32) u32 {
    const rt = self.router orelse return id;
    if (self.dispatch_conn == 0) return id;
    return rt.mapView(rt.ctx, self.dispatch_conn, id);
}

/// The inner frame of a `sem_request` was encoded by the CLIENT, so
/// its view id is in the client's namespace — the socket edge only
/// translates top-level frames. Map it here, through the router.
pub fn innerReq(self: *Host, comptime T: type, payload: []const u8) !T {
    var req = try proto.decode(T, payload);
    req.view = self.mapDispatchView(req.view);
    return req;
}

pub fn semRequest(self: *Host, req: proto.SemRequest) !void {
    if (req.request == 0) return;
    const old_request = self.active_sem_request;
    self.active_sem_request = req.request;
    defer self.active_sem_request = old_request;
    switch (@as(proto.Tag, @enumFromInt(req.kind))) {
        .sem_snapshot_req => try self.semSnapshot(try self.innerReq(proto.SemSnapshotReq, req.payload.s)),
        .sem_act => try self.semAct(try self.innerReq(proto.SemAction, req.payload.s)),
        .sem_expand => try self.semExpand(try self.innerReq(proto.SemExpand, req.payload.s)),
        .sem_query => try self.semQuery(try self.innerReq(proto.SemQueryReq, req.payload.s)),
        .sem_read => try self.semRead(try self.innerReq(proto.SemRead, req.payload.s)),
        .sem_read_ids => try self.semReadIds(try self.innerReq(proto.SemReadIds, req.payload.s)),
        .sem_act_guarded => try self.semActGuarded(try self.innerReq(proto.SemActGuarded, req.payload.s)),
        .sem_eval => try self.semEval(try self.innerReq(proto.SemEval, req.payload.s)),
        else => {},
    }
}

pub fn semAct(self: *Host, req: proto.SemAction) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = discarded_msg });
        return;
    }
    if (v.sem_nav.loading) {
        self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = "semantic action unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" });
        return;
    }
    const eid = v.sem.eidFor(req.id);
    if (eid == 0) {
        self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = v.sem.unknownReason(req.id) });
        return;
    }
    var buf: [512]u8 = undefined;
    switch (@as(proto.SemAct, @enumFromInt(req.action))) {
        .click, .hover => {
            const kind: Pending.Kind = if (req.action == @intFromEnum(proto.SemAct.click)) .click else .hover;
            const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = kind, .sid = req.id });
            const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"locate\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
            self.sendScript(v, cmd);
        },
        .focus, .scroll_into_view => {
            const what = if (req.action == @intFromEnum(proto.SemAct.focus)) "focus" else "scroll";
            const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .act, .sid = req.id });
            const cmd = std.fmt.bufPrint(
                &buf,
                "{{\"op\":\"act\",\"req\":{d},\"eid\":{d},\"action\":\"{s}\"}}",
                .{ rid, eid, what },
            ) catch return;
            self.sendScript(v, cmd);
        },
        .set_value => {
            const arg = try self.gpa.dupe(u8, req.arg);
            errdefer self.gpa.free(arg);
            const rid = try self.pushPending(v, .{
                .req = nextReq(v),
                .kind = .set_value,
                .sid = req.id,
                .arg = arg,
            });
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            cmd.writer.print("{{\"op\":\"setvalue\",\"req\":{d},\"eid\":{d},\"arg\":", .{ rid, eid }) catch return;
            jsonStr(&cmd.writer, req.arg) catch return;
            cmd.writer.writeByte('}') catch return;
            self.sendScript(v, cmd.written());
        },
        _ => self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = "unknown action" }),
    }
}

/// Refresh the live tree before resolving a reader id, then require
/// the exact document generation and revision returned by the read.
pub fn semActGuarded(self: *Host, req: proto.SemActGuarded) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = discarded_msg });
        return;
    }
    if (v.sem_nav.loading) {
        self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = stale_reader_msg });
        return;
    }
    const arg = try self.gpa.dupe(u8, req.arg);
    errdefer self.gpa.free(arg);
    const rid = try self.pushPending(v, .{
        .req = nextReq(v),
        .kind = .guarded_act,
        .sid = req.id,
        .mode = req.action,
        .scope = req.doc_gen,
        .off = req.rev,
        .guard = req.guard,
        .guarded = true,
        .arg = arg,
    });
    var buf: [96]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &buf,
        "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
        .{ rid, v.sem_detail },
    ) catch return;
    self.sendScript(v, cmd);
}

pub fn semExpand(self: *Host, req: proto.SemExpand) !void {
    const v = self.find(req.view) orelse return;
    // A discarded view's shadow tree is empty, so the unknown-id
    // answer below would already fire; saying so explicitly keeps
    // "no text" from reading like a page that had none.
    if (v.discarded) {
        self.post(proto.SemExpandResult{
            .view = v.id,
            .id = req.id,
            .off = req.off,
            .text = discarded_msg,
        });
        return;
    }
    if (v.sem_nav.loading) {
        self.post(proto.SemExpandResult{ .view = v.id, .id = req.id, .off = req.off, .text = "semantic expansion unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" });
        return;
    }
    const eid = v.sem.eidFor(req.id);
    if (eid == 0) {
        self.post(proto.SemExpandResult{ .view = v.id, .id = req.id, .off = req.off, .text = "" });
        return;
    }
    const rid = try self.pushPending(v, .{
        .req = nextReq(v),
        .kind = .expand,
        .sid = req.id,
        .off = req.off,
    });
    var buf: [160]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &buf,
        "{{\"op\":\"expand\",\"req\":{d},\"eid\":{d},\"off\":{d},\"len\":{d}}}",
        .{ rid, eid, req.off, @min(req.len, max_expand) },
    ) catch return;
    self.sendScript(v, cmd);
}

/// Queries are answered from the shadow tree, never by a fresh DOM
/// walk: a spot-check must not cost a traversal and must not invent
/// ids the client has never been told about. The ONE exception is
/// the `visible` (link hints) kind, whose whole answer is rects: it
/// solicits a walk first, because a scroll moves every box without
/// a single mutation the observer could have folded.
pub fn semQuery(self: *Host, req: proto.SemQueryReq) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = discarded_msg } });
        return;
    }
    if (v.sem_nav.loading and req.kind == @intFromEnum(proto.SemQuery.review)) {
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = "{\"pending\":true}" } });
        return;
    }
    if (v.sem_nav.loading and req.kind != @intFromEnum(proto.SemQuery.visible)) {
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = "semantic query unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" } });
        return;
    }
    if (req.kind == @intFromEnum(proto.SemQuery.review)) {
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .review });
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try out.writer.print("{{\"op\":\"review\",\"req\":{d},\"options\":", .{rid});
        try jsonStr(&out.writer, req.arg);
        try out.writer.writeByte('}');
        self.sendScript(v, out.written());
        return;
    }
    if (req.kind == @intFromEnum(proto.SemQuery.visible)) {
        const arg = try self.gpa.dupe(u8, req.arg);
        errdefer self.gpa.free(arg);
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .hints, .rearm = v.sem_nav.loading, .arg = arg });
        if (v.sem_nav.loading) return;
        var buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
            .{ rid, v.sem_detail },
        ) catch return;
        self.sendScript(v, cmd);
        return;
    }
    if (!v.sem.has_tree) {
        // No walk has happened yet (the view was opened with its
        // first snapshot skipped): solicit one and answer from it,
        // so act-by-name does not cost the caller a snapshot turn.
        const arg = try self.gpa.dupe(u8, req.arg);
        errdefer self.gpa.free(arg);
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .query, .mode = req.kind, .rearm = v.sem_nav.loading, .arg = arg });
        if (v.sem_nav.loading) return;
        var buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
            .{ rid, v.sem_detail },
        ) catch return;
        self.sendScript(v, cmd);
        return;
    }
    const text = v.sem.query(req.kind, req.arg) catch return;
    defer self.gpa.free(text);
    self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
}

/// The per-string serialization budget to send the page, clamped.
/// 0 stays 0: it means "the serializer's own default", which is
/// what a client too old to ask for a budget gets.
pub fn evalMaxStr(asked: u32) u32 {
    if (asked == 0) return 0;
    return @min(asked, proto.MAX_EVAL_STR);
}

/// Evaluate script in the page's main world and answer with the
/// serialized result. The REPLY rides the authenticated bridge, so
/// a page cannot forge it; the code itself runs where page script
/// runs, so the RESULT is page-authored data like any other.
pub fn semEval(self: *Host, req: proto.SemEval) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemEvalResult{
            .view = v.id,
            .ok = 0,
            .json = .{ .s = "{\"error\":\"" ++ discarded_msg ++ "\"}" },
        });
        return;
    }
    if (v.sem_nav.loading) {
        self.post(proto.SemEvalResult{ .view = v.id, .ok = 0, .json = .{ .s = "{\"error\":\"semantic evaluation unavailable while the page is navigating (web_navigate action:stop clears a stuck one)\"}" } });
        return;
    }
    // The code is kept with the request: a page whose CSP blocks
    // eval() answers with a `csp` marker, and the retry re-sends
    // these same bytes spliced into the command script instead.
    const code_copy = self.gpa.dupe(u8, req.code.s) catch return;
    const want_await = req.flags & proto.eval_flag_await != 0;
    const timeout: u32 = @min(req.timeout_ms, 120_000);
    const max_str = evalMaxStr(req.max_str);
    const rid = self.pushPending(v, .{
        .req = nextReq(v),
        .kind = .eval,
        .arg = code_copy,
        .eval_await = want_await,
        .eval_timeout_ms = timeout,
        .eval_max_str = max_str,
    }) catch {
        self.gpa.free(code_copy);
        return;
    };
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    cmd.writer.print("{{\"op\":\"eval\",\"req\":{d},\"await\":{s},\"timeout\":{d},\"maxstr\":{d},\"code\":", .{
        rid,
        if (want_await) "true" else "false",
        timeout,
        max_str,
    }) catch return;
    jsonStr(&cmd.writer, req.code.s) catch return;
    cmd.writer.writeByte('}') catch return;
    self.sendScript(v, cmd.written());
}

/// The CSP lane of `sem_eval`: the code compiled INTO the command
/// script as a function literal, which `execute_java_script` runs
/// regardless of the page's CSP - only eval()-of-a-string is
/// governed. Restricted to a single expression by construction; the
/// `evalprobe` sent right behind it turns a parse failure (the
/// whole script dies, nothing replies) into a clear answer instead
/// of a 120s timeout.
pub fn sendEvalSpliced(self: *Host, v: *View, rid: u32, code: []const u8, want_await: bool, timeout: u32, max_str: u32) void {
    if (!host_mod.sem_secret.ok) return;
    const b = v.browser orelse return;
    const gf = b.get_main_frame orelse return;
    const frame: *cef.cef_frame_t = gf(b) orelse return;
    defer release(&frame.base);
    const slot: []const u8 = &host_mod.sem_secret.slot;
    var script: std.Io.Writer.Allocating = .init(self.gpa);
    defer script.deinit();
    script.writer.print(
        "window[\"{s}\"]&&window[\"{s}\"](({{\"op\":\"eval\",\"req\":{d},\"await\":{s},\"timeout\":{d},\"maxstr\":{d},\"fn\":function(){{return(\n",
        .{ slot, slot, rid, if (want_await) "true" else "false", timeout, max_str },
    ) catch return;
    script.writer.writeAll(code) catch return;
    script.writer.print("\n)}}}}),{d})", .{v.sem_nav.generation}) catch return;
    runJs(frame, script.written());
    var probe: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&probe, "{{\"op\":\"evalprobe\",\"req\":{d}}}", .{rid}) catch return;
    self.sendScriptToFrameGen(frame, cmd, v.sem_nav.generation);
}

pub fn semRead(self: *Host, req: proto.SemRead) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = discarded_msg } });
        return;
    }
    const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .read, .rearm = v.sem_nav.loading });
    if (v.sem_nav.loading) return;
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d}}}", .{rid}) catch return;
    self.sendScript(v, cmd);
}

pub fn semReadIds(self: *Host, req: proto.SemReadIds) !void {
    const v = self.find(req.view) orelse return;
    if (v.discarded) {
        self.post(proto.SemReadIdsResult{
            .view = v.id,
            .doc_gen = 0,
            .rev = 0,
            .markdown = .{ .s = discarded_msg },
            .entities = &.{},
        });
        return;
    }
    v.sem_want_observer = true;
    const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .read_ids, .rearm = v.sem_nav.loading });
    if (v.sem_nav.loading) return;
    var buf: [72]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d},\"ids\":true}}", .{rid}) catch return;
    self.sendScript(v, cmd);
    if (!v.sem_observing) {
        v.sem_observing = true;
        self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
    }
}

/// Re-arm a fresh document: a navigation builds a new V8 context,
/// so the observer and the first walk have to be asked for again.
///
/// A snapshot REQUEST sent into the dying context would never be
/// answered (its walk dies with the context), so pending snapshot
/// requests are re-issued here with their original ids — without
/// this, a client that snapshots right after navigating times out.
pub fn semRearm(self: *Host, v: *View) void {
    v.sem_nav.rearmed();
    v.sem_observing = v.sem_want_observer;
    if (v.sem_observing) self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
    var buf: [112]u8 = undefined;
    var reissued = false;
    for (v.pending.items) |*p| {
        if (!p.rearm or p.nav_gen != v.sem_nav.generation) continue;
        p.rearm = false;
        const cmd = switch (p.kind) {
            .snapshot, .hints, .query => std.fmt.bufPrint(
                &buf,
                "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
                .{ p.req, if (p.kind == .snapshot) p.detail else v.sem_detail },
            ) catch continue,
            .read => std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d}}}", .{p.req}) catch continue,
            .read_ids => std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d},\"ids\":true}}", .{p.req}) catch continue,
            else => continue,
        };
        self.sendScript(v, cmd);
        reissued = true;
    }
    if (reissued or !v.sem_observing) return;
    // No request in flight: an unsolicited walk keeps the live tree
    // (queries, action routing) following the navigation.
    const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"snapshot\",\"req\":0,\"detail\":{d}}}", .{v.sem_detail}) catch return;
    self.sendScript(v, cmd);
}

/// Leave the loading state after an explicit stop. Work queued for
/// the aborted document cannot be reissued safely; answer it now and
/// solicit a fresh unsolicited walk for later ordinary operations.
pub fn semanticStopped(self: *Host, v: *View) void {
    v.sem_nav.rearmed();
    v.sem_context_doc = 0;
    v.sem.invalidateDocument();
    var i: usize = 0;
    while (i < v.pending.items.len) {
        if (!v.pending.items[i].rearm) {
            i += 1;
            continue;
        }
        const p = v.pending.orderedRemove(i);
        self.failPending(v, p, "semantic request canceled because loading was stopped");
    }
    if (v.sem_want_observer) {
        v.sem_observing = true;
        self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
        var buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"snapshot\",\"req\":0,\"detail\":{d}}}", .{v.sem_detail}) catch return;
        self.sendScript(v, cmd);
    }
}

/// One reply from the injected script: `<nonce><json>`.
///
/// The nonce gate is the whole reason the render side has a secret.
/// A page cannot reach the native reply function, but if it ever
/// did, an unprefixed message buys it nothing: everything below is
/// reached only by a message that carries the browser's own nonce,
/// and only for a request id the browser is actually waiting on.
pub fn onScriptMessage(self: *Host, v: *View, raw: []const u8) void {
    if (!host_mod.sem_secret.ok) return;
    if (raw.len <= host_mod.sem_secret.nonce.len) return;
    if (!secretEql(raw[0..host_mod.sem_secret.nonce.len], &host_mod.sem_secret.nonce)) return;
    const json = raw[host_mod.sem_secret.nonce.len..];
    const Head = struct { op: []const u8 = "", req: u32 = 0, doc: u32 = 0, gen: u32 = 0 };
    const head = std.json.parseFromSlice(Head, self.gpa, json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer head.deinit();
    const op = head.value.op;
    const rid = head.value.req;
    // WebExtensions traffic rides the same authenticated channel;
    // route every `ext-*` op to the webext handler.
    if (op.len > 4 and std.mem.eql(u8, op[0..4], "ext-")) {
        self.onExtMessage(v, op, json);
        return;
    }
    // Userscript GM_* calls ride it too, authorised by the script's
    // own capability rather than by navigation generation.
    if (std.mem.eql(u8, op, "us-call")) {
        self.usCall(v, json);
        return;
    }
    if (head.value.gen != v.sem_nav.generation) return;
    if (head.value.doc == 0) return;
    if (v.sem_context_doc == 0) {
        v.sem_context_doc = head.value.doc;
    } else if (head.value.doc != v.sem_context_doc) return;
    if (rid != 0) {
        const p = self.pendingFor(v, rid) orelse return;
        if (p.nav_gen != v.sem_nav.generation) return;
    }
    if (std.mem.eql(u8, op, "tree")) {
        self.onTree(v, rid, json);
        return;
    }
    var p = self.takePending(v, rid) orelse return;
    defer self.freePending(p);
    const old_request = self.active_sem_request;
    self.active_sem_request = p.client_request;
    defer self.active_sem_request = old_request;

    if (std.mem.eql(u8, op, "rect")) {
        self.onRect(v, &p, json);
    } else if (std.mem.eql(u8, op, "optrect")) {
        self.onOptionRect(v, &p, json);
    } else if (std.mem.eql(u8, op, "eval")) {
        const E = struct { ok: u8 = 0, csp: u8 = 0, json: []const u8 = "" };
        const e = std.json.parseFromSlice(E, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        // eval() refused by the page's CSP: re-send the same code
        // spliced into the command script (single-shot), and only
        // answer the client from THAT attempt.
        if (e.value.ok == 0 and e.value.csp == 1 and !p.eval_retried and p.arg.len > 0) {
            var again = p;
            again.eval_retried = true;
            const code = again.arg;
            if (self.pushPending(v, again)) |_| {
                p.arg = &.{}; // the re-queued copy owns the code now
                self.sendEvalSpliced(v, again.req, code, again.eval_await, again.eval_timeout_ms, again.eval_max_str);
                return;
            } else |_| {}
        }
        const rewritten = self.rewriteNodeRefs(v, e.value.json) catch null;
        defer if (rewritten) |r| self.gpa.free(r);
        const body = rewritten orelse e.value.json;
        // An unframeable reply must not be DROPPED: `post` swallows
        // the encode error and the caller then waits out its whole
        // deadline for a result that was already computed.
        if (body.len > proto.MAX_EVAL_JSON) {
            var msg: [256]u8 = undefined;
            const text = std.fmt.bufPrint(
                &msg,
                "{{\"error\":\"the evaluation's result serialized to {d} bytes, past the {d}-byte frame limit; return less (slice it, or read it in pages)\"}}",
                .{ body.len, proto.MAX_EVAL_JSON },
            ) catch "{\"error\":\"the evaluation's result is too large to return\"}";
            self.post(proto.SemEvalResult{ .view = v.id, .ok = 0, .json = .{ .s = text } });
            return;
        }
        self.post(proto.SemEvalResult{
            .view = v.id,
            .ok = e.value.ok,
            .json = .{ .s = body },
        });
    } else if (std.mem.eql(u8, op, "review") and p.kind == .review) {
        if (json.len > 131072) {
            self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = "review exceeded its 128KiB response budget" } });
            return;
        }
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = json } });
    } else if (std.mem.eql(u8, op, "setvalue")) {
        self.onSetValue(v, &p, json);
    } else if (std.mem.eql(u8, op, "ack")) {
        const Ack = struct { ok: u8 = 0, msg: []const u8 = "", note: []const u8 = "" };
        const a = std.json.parseFromSlice(Ack, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer a.deinit();
        var buf: [512]u8 = undefined;
        const msg = switch (p.kind) {
            .commit => if (a.value.note.len > 0)
                std.fmt.bufPrint(&buf, "set-value ok, value=\"{s}\" ({s})", .{
                    a.value.msg[0..@min(a.value.msg.len, 128)],
                    a.value.note[0..@min(a.value.note.len, 160)],
                }) catch a.value.msg
            else
                std.fmt.bufPrint(&buf, "set-value ok, value=\"{s}\"", .{
                    a.value.msg[0..@min(a.value.msg.len, 128)],
                }) catch a.value.msg,
            .choose_done => std.fmt.bufPrint(
                &buf,
                "custom dropdown: clicked option \"{s}\" (trusted); control now \"{s}\"",
                .{ p.arg[0..@min(p.arg.len, 128)], a.value.msg[0..@min(a.value.msg.len, 128)] },
            ) catch a.value.msg,
            else => a.value.msg,
        };
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = a.value.ok, .msg = msg });
    } else if (std.mem.eql(u8, op, "text")) {
        const Txt = struct { off: u32 = 0, text: []const u8 = "" };
        const t = std.json.parseFromSlice(Txt, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer t.deinit();
        self.post(proto.SemExpandResult{
            .view = v.id,
            .id = p.sid,
            .off = t.value.off,
            .text = t.value.text[0..@min(t.value.text.len, max_expand)],
        });
    } else if (std.mem.eql(u8, op, "markdown") and p.kind == .read_ids) {
        const tree = semantic.parseTree(self.gpa, json) catch return;
        defer tree.deinit();
        v.sem.apply(tree.value) catch return;
        const parsed = std.json.parseFromSlice(semantic.InReader, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const result = v.sem.readerResult(self.gpa, parsed.value) catch return;
        defer self.gpa.free(result.entities);
        var entities = self.gpa.alloc(proto.ReaderEntity, result.entities.len) catch return;
        defer self.gpa.free(entities);
        for (result.entities, 0..) |entity, i| {
            entities[i] = .{ .id = entity.id, .guard = entity.guard, .kind = entity.kind, .text = entity.text, .url = entity.url };
        }
        self.post(proto.SemReadIdsResult{
            .view = v.id,
            .doc_gen = result.doc_gen,
            .rev = result.rev,
            .markdown = .{ .s = result.markdown },
            .entities = entities,
        });
    } else if (std.mem.eql(u8, op, "markdown")) {
        const Md = struct { md: []const u8 = "" };
        const m = std.json.parseFromSlice(Md, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer m.deinit();
        self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = m.value.md } });
    }
}

/// A full DOM walk, folded into the LIVE shadow tree either way. An
/// unsolicited batch (req 0, the MutationObserver) posts NOTHING —
/// the client is answered with one coalesced delta when it next
/// asks (semantic.View.consume), so churn that appeared and
/// vanished in between is never replayed at it.
pub fn onTree(self: *Host, v: *View, rid: u32, json: []const u8) void {
    const pend = self.takePending(v, rid);
    // A named request id that nothing is waiting on was either
    // answered already or never asked for; only the observer's
    // unsolicited id 0 may arrive without a pending entry.
    if (rid != 0 and pend == null) return;
    defer if (pend) |p| self.freePending(p);
    const old_request = self.active_sem_request;
    self.active_sem_request = if (pend) |p| p.client_request else 0;
    defer self.active_sem_request = old_request;
    const parsed = semantic.parseTree(self.gpa, json) catch return;
    defer parsed.deinit();
    v.sem.apply(parsed.value) catch return;
    const p = pend orelse return;

    if (p.kind == .guarded_act) {
        if (!v.sem.revisionMatches(p.scope, p.off) or v.sem.actionGuard(p.sid) != p.guard) {
            self.post(proto.SemActResult{
                .view = v.id,
                .id = p.sid,
                .ok = 0,
                .msg = "stale reader id: the page changed since web_read; read the page again",
            });
            return;
        }
        self.semActAfterGuard(v, p);
        return;
    }

    if (p.kind == .query) {
        const text = v.sem.query(p.mode, p.arg) catch return;
        defer self.gpa.free(text);
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
        return;
    }

    if (p.kind == .hints) {
        // Link hints: the walk just folded, so the live tree's rects
        // are current. Renders from the live tree and does NOT
        // consume the base — a hints pass must not eat the delta a
        // real snapshot request is owed.
        var vw: i32 = std.math.maxInt(i32);
        var vh: i32 = std.math.maxInt(i32);
        var it = std.mem.tokenizeScalar(u8, p.arg, ' ');
        if (it.next()) |s| vw = std.fmt.parseInt(i32, s, 10) catch vw;
        if (it.next()) |s| vh = std.fmt.parseInt(i32, s, 10) catch vh;
        const text = v.sem.renderHints(vw, vh) catch return;
        defer self.gpa.free(text);
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
        return;
    }

    if (p.scope != 0) {
        // A scoped snapshot is one subtree rendered in full; it
        // advances the base for THAT subtree only (the caller did
        // not see the rest of the page).
        const scoped = v.sem.consumeScoped(p.scope) catch return;
        defer self.gpa.free(scoped);
        self.post(proto.SemSnapshot{
            .view = v.id,
            .doc_gen = v.sem.doc_gen,
            .rev = v.sem.rev,
            .kind = @intFromEnum(proto.SnapKind.full),
            .payload = .{ .s = scoped },
        });
        return;
    }
    if (p.mode == @intFromEnum(proto.SnapMode.peek)) {
        // A probe: the walk folded into the live tree, the answer
        // is the revision, and the base is untouched.
        self.post(proto.SemSnapshot{
            .view = v.id,
            .doc_gen = v.sem.doc_gen,
            .rev = v.sem.rev,
            .kind = @intFromEnum(proto.SnapKind.delta),
            .payload = .{ .s = "" },
        });
        return;
    }
    const mode: semantic.Mode = switch (p.mode) {
        @intFromEnum(proto.SnapMode.full) => .full,
        @intFromEnum(proto.SnapMode.history) => .history,
        else => .auto,
    };
    const up = v.sem.consume(mode) catch return;
    defer self.gpa.free(up.text);
    self.post(proto.SemSnapshot{
        .view = v.id,
        .doc_gen = up.doc_gen,
        .rev = up.rev,
        .kind = @intFromEnum(up.kind),
        .payload = .{ .s = up.text },
    });
}

/// Continue a guarded action without dropping its identity fence.
/// Every second-phase request is marked guarded, so navigation
/// before the trusted input is delivered fails it explicitly.
pub fn semActAfterGuard(self: *Host, v: *View, p: Pending) void {
    const eid = v.sem.eidFor(p.sid);
    if (eid == 0) {
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = stale_reader_msg });
        return;
    }
    var buf: [512]u8 = undefined;
    switch (@as(proto.SemAct, @enumFromInt(p.mode))) {
        .click, .hover => {
            const kind: Pending.Kind = if (p.mode == @intFromEnum(proto.SemAct.click)) .click else .hover;
            const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = kind, .sid = p.sid, .guarded = true }) catch return;
            const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"locate\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
            self.sendScript(v, cmd);
        },
        .focus, .scroll_into_view => {
            const what = if (p.mode == @intFromEnum(proto.SemAct.focus)) "focus" else "scroll";
            const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .act, .sid = p.sid, .guarded = true }) catch return;
            const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"act\",\"req\":{d},\"eid\":{d},\"action\":\"{s}\"}}", .{ rid, eid, what }) catch return;
            self.sendScript(v, cmd);
        },
        .set_value => {
            const arg = self.gpa.dupe(u8, p.arg) catch return;
            const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .set_value, .sid = p.sid, .guarded = true, .arg = arg }) catch {
                self.gpa.free(arg);
                return;
            };
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            cmd.writer.print("{{\"op\":\"setvalue\",\"req\":{d},\"eid\":{d},\"arg\":", .{ rid, eid }) catch return;
            jsonStr(&cmd.writer, p.arg) catch return;
            cmd.writer.writeByte('}') catch return;
            self.sendScript(v, cmd.written());
        },
        _ => self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = "unknown action" }),
    }
}

/// The script located an element: the click or hover is synthesized
/// HERE, through the same input path a human uses, which is the
/// whole reason `element.click()` is not an option.
pub fn onRect(self: *Host, v: *View, p: *Pending, json: []const u8) void {
    const R = struct { ok: u8 = 0, x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };
    const r = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer r.deinit();
    if (r.value.ok == 0) {
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = if (p.guarded) stale_reader_msg else "element has no box" });
        return;
    }
    const pt = viewPoint(v, r.value.x, r.value.y);
    var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
    withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
    // Echo WHAT the id resolved to, not only where the pointer
    // went: a mis-resolved id is invisible in bare coordinates.
    var target_buf: [140]u8 = undefined;
    const target: []const u8 = if (v.sem.describe(p.sid)) |d|
        std.fmt.bufPrint(&target_buf, "on {s} \"{s}\" ", .{ d.role, d.name[0..@min(d.name.len, 96)] }) catch ""
    else
        "";
    // ...and WHERE: with N identical "Edit" buttons the target alone
    // is the same string for the wrong row and the right one.
    var ctx_buf: [160]u8 = undefined;
    const ctx: []const u8 = if (v.sem.describeContext(p.sid)) |cx|
        std.fmt.bufPrint(&ctx_buf, "in {s} \"{s}\" ", .{ cx.role, cx.name[0..@min(cx.name.len, 120)] }) catch ""
    else
        "";
    var buf: [400]u8 = undefined;
    if (p.kind == .hover) {
        const msg = std.fmt.bufPrint(&buf, "hover {s}{s}at {d},{d}", .{ target, ctx, r.value.x, r.value.y }) catch "hover";
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 1, .msg = msg });
        return;
    }
    withHostArgs(v, setFocus, .{@as(c_int, 1)});
    withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
    withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
    const msg = std.fmt.bufPrint(&buf, "click {s}{s}at {d},{d}", .{ target, ctx, r.value.x, r.value.y }) catch "click";
    self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 1, .msg = msg });
}

/// A custom dropdown's option, located after the trusted click that
/// opened the list: clicking it is trusted too, which is the whole
/// reason this is a round trip instead of `option.click()`.
pub fn onOptionRect(self: *Host, v: *View, p: *Pending, json: []const u8) void {
    const R = struct {
        ok: u8 = 0,
        x: i32 = 0,
        y: i32 = 0,
        text: []const u8 = "",
        seen: []const u8 = "",
    };
    const r = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer r.deinit();
    var buf: [512]u8 = undefined;
    if (r.value.ok == 0) {
        const msg = std.fmt.bufPrint(
            &buf,
            "no option matched \"{s}\" in the opened dropdown; options seen: {s}",
            .{ p.arg[0..@min(p.arg.len, 96)], r.value.seen[0..@min(r.value.seen.len, 300)] },
        ) catch "no matching option in the opened dropdown";
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = msg });
        return;
    }
    const pt = viewPoint(v, r.value.x, r.value.y);
    var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
    withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
    withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
    withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });

    const picked = self.gpa.dupe(u8, r.value.text) catch return;
    const eid = v.sem.eidFor(p.sid);
    const rid = self.pushPending(v, .{
        .req = nextReq(v),
        .kind = .choose_done,
        .sid = p.sid,
        .guarded = p.guarded,
        .arg = picked,
    }) catch {
        self.gpa.free(picked);
        return;
    };
    const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"chosen\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
    self.sendScript(v, cmd);
}

/// Replace the script's `{"__kind":"node","eid":N,...}` markers with
/// PROTOCOL-facing `{"semantic_id":S,...}`, so an eval result that
/// returned an element can be fed straight back into `sem_act`. An
/// element the current tree does not hold answers null.
pub fn rewriteNodeRefs(self: *Host, v: *View, json: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, json, "\"__kind\":\"node\"") == null) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, json, .{}) catch return null;
    defer parsed.deinit();
    var root = parsed.value;
    try rewriteValue(v, parsed.arena.allocator(), &root);
    var aw: std.Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    try std.json.Stringify.value(root, .{}, &aw.writer);
    return try aw.toOwnedSlice();
}

pub fn rewriteValue(v: *View, arena: std.mem.Allocator, node: *std.json.Value) !void {
    switch (node.*) {
        .array => |*arr| for (arr.items) |*item| try rewriteValue(v, arena, item),
        .object => |*obj| {
            const kind = obj.get("__kind");
            const eid_v = obj.get("eid");
            if (kind != null and kind.? == .string and std.mem.eql(u8, kind.?.string, "node") and
                eid_v != null and eid_v.? == .integer)
            {
                const eid: u32 = if (eid_v.?.integer > 0) @intCast(eid_v.?.integer) else 0;
                const sid = if (eid != 0) v.sem.sidFor(eid) else 0;
                _ = obj.orderedRemove("__kind");
                _ = obj.orderedRemove("eid");
                try obj.put(arena, "semantic_id", if (sid != 0)
                    std.json.Value{ .integer = @intCast(sid) }
                else
                    std.json.Value{ .null = {} });
                if (sid == 0) try obj.put(
                    arena,
                    "note",
                    .{ .string = "this element is not in the current snapshot; take a web_snapshot to act on it" },
                );
                // The row it sits in, so a caller can fall back to
                // web_act within_text instead of an index when the
                // page re-renders the element before the act.
                if (sid != 0) if (v.sem.describeContext(sid)) |cx| {
                    const ctx = try std.fmt.allocPrint(arena, "{s} \"{s}\"", .{ cx.role, cx.name });
                    try obj.put(arena, "context", .{ .string = ctx });
                };
                return;
            }
            var it = obj.iterator();
            while (it.next()) |entry| try rewriteValue(v, arena, entry.value_ptr);
        },
        else => {},
    }
}

/// Set-value: a typeable field is TYPED into with real key events;
/// a native select (including one in an open shadow root) picks the
/// matching option; a custom/ARIA dropdown is opened with a trusted
/// click here and its option picked in `onOptionRect`; anything
/// else can only be assigned from script, and the reply says so
/// rather than pretending.
pub fn onSetValue(self: *Host, v: *View, p: *Pending, json: []const u8) void {
    const S = struct {
        ok: u8 = 0,
        typeable: u8 = 0,
        custom: u8 = 0,
        x: i32 = 0,
        y: i32 = 0,
        msg: []const u8 = "",
    };
    const s = std.json.parseFromSlice(S, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer s.deinit();
    if (s.value.ok == 0) {
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = s.value.msg });
        return;
    }
    if (s.value.custom != 0) {
        // Open the list with a real click, then go looking for the
        // option; both clicks are trusted, which is what a custom
        // dropdown's own key handlers need to see.
        const pt = viewPoint(v, s.value.x, s.value.y);
        var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
        withHostArgs(v, setFocus, .{@as(c_int, 1)});
        withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
        const want = self.gpa.dupe(u8, p.arg) catch return;
        const rid = self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .choose_pick,
            .sid = p.sid,
            .guarded = p.guarded,
            .arg = want,
        }) catch {
            self.gpa.free(want);
            return;
        };
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        cmd.writer.print("{{\"op\":\"pickoption\",\"req\":{d},\"timeout\":4000,\"arg\":", .{rid}) catch return;
        jsonStr(&cmd.writer, p.arg) catch return;
        cmd.writer.writeByte('}') catch return;
        self.sendScript(v, cmd.written());
        return;
    }
    if (s.value.typeable == 0) {
        self.post(proto.SemActResult{
            .view = v.id,
            .id = p.sid,
            .ok = 1,
            .msg = if (s.value.msg.len > 0)
                s.value.msg
            else
                "set-value applied by script (element is not typeable; input+change dispatched)",
        });
        return;
    }
    withHostArgs(v, setFocus, .{@as(c_int, 1)});
    typeText(v, p.arg);
    const eid = v.sem.eidFor(p.sid);
    const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .commit, .sid = p.sid, .guarded = p.guarded }) catch return;
    // The keystrokes are queued input and this script is an IPC to
    // the renderer: they race. `want` lets the commit read wait
    // (bounded) for the typed text to land before reporting.
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    cmd.writer.print("{{\"op\":\"commit\",\"req\":{d},\"eid\":{d},\"want\":", .{ rid, eid }) catch return;
    jsonStr(&cmd.writer, p.arg) catch return;
    cmd.writer.writeByte('}') catch return;
    self.sendScript(v, cmd.written());
}

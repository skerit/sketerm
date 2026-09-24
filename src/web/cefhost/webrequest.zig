//! Blocking webRequest (MV2), split out of `cefhost.zig`: the held-request
//! path on CEF's IO thread and its main-thread half (the pump that asks
//! each extension's background page and answers every held request).
//! The `Host` methods are free functions taking `*Host`, re-exported from
//! `Host` under their old names.

const std = @import("std");
const SpinLock = @import("../../util/spinlock.zig").SpinLock;
const c = @import("cbindings");
const cef = @import("cef");
const nowMs = @import("../../util/clock.zig").nowMs;
const nowUs = @import("../../util/clock.zig").nowUs;
const proto = @import("../protocol.zig");
const webexthost = @import("../webext/host.zig");
const webrequest = @import("../webext/webrequest.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const Utf8 = host_mod.Utf8;
const View = host_mod.View;
const jsonStr = host_mod.jsonStr;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const setStr = host_mod.setStr;
const userfreeInto = host_mod.userfreeInto;

// -- blocking webRequest, main-thread half ------------------------

/// Called once per poll iteration. Three jobs, all of which have to
/// happen on this thread because they touch a browser or the
/// registry: move each held chain on to its next extension, dispatch
/// what is queued, and move past (never cancel on) an extension that
/// missed its deadline.
///
/// Cheap when idle: one relaxed atomic load and a return.
pub fn webrequestPump(self: *Host) void {
    if (!webrequestBusy()) return;
    webrequestDrainWake();

    // Chains first: an advance either queues the next dispatch
    // (picked up below, this same turn) or answers the request.
    {
        var adv: [MAX_HOLDS]u32 = undefined;
        var nadv: usize = 0;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            for (&g_wreq.holds) |*h| {
                if (h.used and h.advance) {
                    adv[nadv] = h.hid;
                    nadv += 1;
                }
            }
        }
        for (adv[0..nadv]) |hid| self.wreqAdvance(hid);
    }

    // One pass, copying what we need out under the lock — sending a
    // command re-enters CEF and must not run with the spinlock held.
    const Job = struct {
        hid: u32,
        gen: u32,
        bg_view: u32,
        ext: usize,
        event: webrequest.Event,
        rtype: u8,
        view_id: u32,
        with_headers: bool,
        observational: bool,
        held: bool,
        url: [HOLD_URL_MAX]u8,
        url_len: u16,
        method: [8]u8,
        method_len: u8,
        hdr: [HOLD_HDR_MAX]u8,
        hdr_len: u16,
        extra: [256]u8,
        extra_len: u16,
        lids: [webrequest.MAX_MATCHED]u32,
        n_lids: u8,
    };
    var jobs: [MAX_HOLDS]Job = undefined;
    var njobs: usize = 0;
    var expired: [MAX_HOLDS]u32 = undefined;
    var nexpired: usize = 0;
    const now = nowMs();
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.holds) |*h| {
            if (!h.used or h.advance) continue;
            if (h.dispatched) {
                if (now >= h.deadline_ms) {
                    expired[nexpired] = h.hid;
                    nexpired += 1;
                }
                continue;
            }
            h.dispatched = true;
            const j = &jobs[njobs];
            njobs += 1;
            j.* = .{
                .hid = h.hid,
                .gen = h.gen,
                .bg_view = h.bg_view,
                .ext = h.ext,
                .event = h.event,
                .rtype = h.rtype,
                .view_id = h.view_id,
                .with_headers = h.want_request_headers,
                .observational = !h.cur_blocking,
                .held = h.cb != null,
                .url = h.url,
                .url_len = h.url_len,
                .method = h.method,
                .method_len = h.method_len,
                .hdr = h.hdr,
                .hdr_len = h.hdr_len,
                .extra = h.extra,
                .extra_len = h.extra_len,
                .lids = h.lids,
                .n_lids = h.n_lids,
            };
        }
    }

    for (jobs[0..njobs]) |*j| {
        var ext_buf: [webrequest.MAX_ID]u8 = undefined;
        var ext_len: usize = 0;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            if (wstatIdx(j.ext)) |s| {
                ext_len = s.id_len;
                @memcpy(ext_buf[0..ext_len], s.idSlice());
            }
        }
        const bg = self.find(j.bg_view);
        const e_opt = if (ext_len == 0) null else self.webext.find(ext_buf[0..ext_len]);
        if (ext_len == 0 or bg == null or e_opt == null) {
            // The listener became unreachable between the hold and
            // this dispatch: skip this extension (a mailbox simply
            // retires).
            self.wreqStepDone(j.hid, j.gen, j.held);
            continue;
        }
        const e = e_opt.?;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        self.writeWreqCommand(&cmd.writer, e, j, now) catch {
            self.wreqStepDone(j.hid, j.gen, j.held);
            continue;
        };
        self.sendScript(bg.?, cmd.written());
        // A main-frame response started: until the new document
        // commits, a `document_start` executeScript is for IT.
        if (j.event == .response_started and @as(webrequest.RType, @enumFromInt(j.rtype)) == .main_frame) {
            if (self.find(j.view_id)) |pv| pv.exec_nav_pending = true;
        }
        // An OBSERVATIONAL notification is a mailbox drop, not a
        // question: no decision is coming back. A mailbox slot is
        // retired the moment the command is out, so a page full of
        // non-blocking notifications never occupies the hold table;
        // a held chain moves on to its next extension.
        if (j.observational) self.wreqStepDone(j.hid, j.gen, j.held);
    }

    for (expired[0..nexpired]) |hid| {
        g_wreq.acquire();
        if (wreqFind(hid)) |h| {
            if (wstatIdx(h.ext)) |s| {
                s.timed_out +%= 1;
                s.failed_open +%= 1;
            }
            // A timeout moves PAST the slow extension, it NEVER
            // cancels: a wedged or slow extension must degrade the
            // browser's filtering, not its ability to load pages.
            if (h.cb != null) {
                h.advance = true;
                h.dispatched = false;
            }
        }
        g_wreq.release();
        // A mailbox with nobody listening any more just retires.
        self.wreqRetire(hid);
        wreqPoke();
    }
}

/// The `ext-wreq` command for one dispatch.
pub fn writeWreqCommand(self: *Host, w: *std.Io.Writer, e: *const webexthost.Extension, j: anytype, now: i64) !void {
    try w.writeAll("{\"op\":\"ext-wreq\",\"ext\":");
    try jsonStr(w, e.id);
    try w.writeAll(",\"cap\":");
    try jsonStr(w, &e.capability);
    try w.print(",\"hid\":{d},\"g\":{d},\"event\":", .{ j.hid, j.gen });
    try jsonStr(w, j.event.toStr());
    try w.writeAll(",\"details\":{\"requestId\":");
    var rid_buf: [24]u8 = undefined;
    const rid = std.fmt.bufPrint(&rid_buf, "{d}", .{j.hid}) catch "0";
    try jsonStr(w, rid);
    try w.writeAll(",\"url\":");
    try jsonStr(w, j.url[0..j.url_len]);
    try w.writeAll(",\"method\":");
    try jsonStr(w, if (j.method_len == 0) "GET" else j.method[0..j.method_len]);
    try w.writeAll(",\"type\":");
    const rt: webrequest.RType = @enumFromInt(j.rtype);
    try jsonStr(w, rt.toStr());
    // THE TAB ID IS LOAD-BEARING, not decoration. MV2 defines
    // -1 as "not associated with a tab", and uBlock Origin's
    // `onBeforeRequest` reads exactly that: `if (tabId < 0)` it
    // takes its BEHIND-THE-SCENE path, where a page it has no
    // store for is handled by different rules — measured here as
    // uBO cancelling the top-level navigation of every page.
    // So the real tab is looked up from the client's mirrored
    // list, and -1 survives only for a view no tab claims (a
    // background page's own fetch, which IS tabless).
    const tab_id: i64 = if (self.webext.tabs.findByView(j.view_id)) |tb|
        @intCast(tb.id)
    else
        -1;
    // Frame attribution is coarse: the main frame is 0 and a
    // subresource is attributed to it (parent -1) too.
    try w.print(",\"tabId\":{d},\"frameId\":0,\"parentFrameId\":-1,\"timeStamp\":{d}", .{ tab_id, now });
    // `documentUrl`/`originUrl` describe the document that CAUSED
    // the request, and MV2 OMITS them for a top-level navigation
    // — the document is the request. Sending the view's previous
    // url there (`about:blank` on a fresh view) makes a page
    // third-party to ITSELF, and uBO then strict-blocks the
    // navigation: measured as every page failing ERR_ABORTED.
    if (rt != .main_frame) {
        // OUR OWN view's url wins over the client's mirrored tab.
        // `v.url` is set in-process by `on_address_change`; the
        // tab table is at minimum a full round trip behind it
        // (helper -> socket -> GUI -> a coalescing idle -> back),
        // so right after a navigation the mirror still names the
        // PREVIOUS page. That made a page's own subresources
        // third-party to itself, which is exactly what uBO
        // strict-blocks. The mirror supplies IDENTITY (tabId),
        // never the url.
        const doc: []const u8 = if (self.find(j.view_id)) |pv| blk: {
            if (pv.url.len != 0) break :blk pv.url;
            break :blk if (self.webext.tabs.findByView(j.view_id)) |tb| tb.url else "";
        } else if (self.webext.tabs.findByView(j.view_id)) |tb| tb.url else "";
        if (doc.len != 0) {
            try w.writeAll(",\"documentUrl\":");
            try jsonStr(w, doc);
            try w.writeAll(",\"originUrl\":");
            try jsonStr(w, doc);
        }
    }
    if (j.with_headers and j.hdr_len != 0) {
        const hdr_key: []const u8 = switch (j.event) {
            .headers_received, .response_started, .completed => ",\"responseHeaders\":",
            else => ",\"requestHeaders\":",
        };
        try w.writeAll(hdr_key);
        try w.writeAll(j.hdr[0..j.hdr_len]);
    }
    if (j.extra_len != 0) {
        try w.writeByte(',');
        try w.writeAll(j.extra[0..j.extra_len]);
    }
    if (j.observational) try w.writeAll(",\"obs\":true");
    try w.writeAll("}");
    // The listener ids whose own filter matched. The frame runs
    // ONLY these.
    try w.writeAll(",\"lids\":[");
    for (j.lids[0..j.n_lids], 0..) |lid, li| {
        if (li != 0) try w.writeByte(',');
        try w.print("{d}", .{lid});
    }
    try w.writeByte(']');
    if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) try w.writeAll(",\"dbg\":true");
    try w.writeByte('}');
}

/// One step of a hold is finished without a decision to fold: a
/// mailbox retires, a held chain moves on. `gen` guards against a
/// step that was already superseded.
pub fn wreqStepDone(self: *Host, hid: u32, gen: u32, held: bool) void {
    if (!held) {
        self.wreqRetire(hid);
        return;
    }
    g_wreq.acquire();
    defer g_wreq.release();
    const h = wreqFind(hid) orelse return;
    if (h.gen != gen) return;
    h.advance = true;
    h.dispatched = false;
    wreqPoke();
}

/// Move a held chain to the next extension whose filters match,
/// `onBeforeRequest` across every extension first, then
/// `onBeforeSendHeaders` (skipped once a redirect is decided: the
/// redirect restarts the request and its own headers phase runs on
/// the new load). With nobody left, the verdict is applied.
pub fn wreqAdvance(self: *Host, hid: u32) void {
    var url_buf: [HOLD_URL_MAX]u8 = undefined;
    var url_len: usize = 0;
    var rtype: webrequest.RType = .other;
    var ev: webrequest.Event = .before_request;
    var cur: i32 = -1;
    var held = false;
    var redirected = false;
    var cancelled = false;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        const h = wreqFind(hid) orelse return;
        url_len = h.url_len;
        @memcpy(url_buf[0..url_len], h.url[0..url_len]);
        rtype = @enumFromInt(h.rtype);
        ev = h.event;
        cur = h.cursor;
        held = h.cb != null;
        redirected = h.verdict.redirect_len != 0;
        cancelled = h.verdict.cancel;
    }
    if (!held) {
        self.wreqRetire(hid);
        return;
    }
    const url = url_buf[0..url_len];
    while (!cancelled) {
        var found = false;
        var idx: usize = 0;
        var id_buf: [webrequest.MAX_ID]u8 = undefined;
        var id_len: usize = 0;
        var bg: u32 = 0;
        var need = webrequest.Need.none();
        {
            webrequest.acquire();
            defer webrequest.release();
            var i: usize = @intCast(cur + 1);
            while (i < webrequest.slots.len) : (i += 1) {
                const s = &webrequest.slots[i];
                if (!s.used) continue;
                const reg = s.reg orelse continue;
                const n = webrequest.needFor(reg, ev, url, rtype);
                if (n.isNone()) continue;
                found = true;
                idx = i;
                id_len = s.id_len;
                @memcpy(id_buf[0..id_len], s.idSlice());
                bg = s.bg_view;
                need = n;
                break;
            }
        }
        if (found) {
            cur = @intCast(idx);
            if (bg == 0) {
                // Nobody to ask for this one; the chain goes on.
                g_wreq.acquire();
                if (wstatFor(id_buf[0..id_len])) |st| {
                    st.matched +%= 1;
                    if (need.blocking) st.failed_open +%= 1;
                }
                g_wreq.release();
                continue;
            }
            // The headers phase shows each extension the headers the
            // previous one left: re-read them from the request.
            var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
            var hdr_len: u16 = 0;
            if (ev == .before_send_headers) {
                var req: ?*cef.cef_request_t = null;
                {
                    g_wreq.acquire();
                    defer g_wreq.release();
                    const h = wreqFind(hid) orelse return;
                    req = h.req;
                    if (req) |r| if (r.base.add_ref) |ar| ar(&r.base);
                }
                if (req) |r| {
                    hdr_len = headerMapJson(r, &hdr_buf);
                    release(&r.base);
                }
            }
            g_wreq.acquire();
            defer g_wreq.release();
            const h = wreqFind(hid) orelse return;
            const st = wstatFor(id_buf[0..id_len]);
            if (st) |s| {
                s.matched +%= 1;
                if (need.blocking) s.held +%= 1;
            }
            h.ext = if (st) |s| (@intFromPtr(s) - @intFromPtr(&g_wreq.stats[0])) / @sizeOf(WStat) else 0;
            h.bg_view = bg;
            h.cursor = @intCast(idx);
            h.event = ev;
            h.cur_blocking = need.blocking;
            h.want_request_headers = need.want_request_headers or ev == .before_send_headers;
            if (ev == .before_send_headers) {
                h.hdr_len = hdr_len;
                if (hdr_len != 0) @memcpy(h.hdr[0..hdr_len], hdr_buf[0..hdr_len]);
            }
            setHoldLids(h, &need);
            h.advance = false;
            h.dispatched = false;
            h.gen +%= 1;
            h.start_us = nowUs();
            h.deadline_ms = nowMs() + g_wreq.timeout_ms;
            return;
        }
        if (ev == .before_request and !redirected) {
            ev = .before_send_headers;
            cur = -1;
            continue;
        }
        break;
    }
    self.wreqFinish(hid);
}

/// Answer a held request with its folded verdict and free the slot.
pub fn wreqFinish(self: *Host, hid: u32) void {
    var cb: ?*cef.cef_callback_t = null;
    var req: ?*cef.cef_request_t = null;
    var verdict: webrequest.Verdict = .{};
    var url_buf: [HOLD_URL_MAX]u8 = undefined;
    var url_len: usize = 0;
    var method_buf: [8]u8 = undefined;
    var method_len: usize = 0;
    var rtype: webrequest.RType = .other;
    var view_id: u32 = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        const h = wreqFind(hid) orelse return;
        cb = h.cb;
        req = h.req;
        verdict = h.verdict;
        url_len = h.url_len;
        @memcpy(url_buf[0..url_len], h.url[0..url_len]);
        method_len = h.method_len;
        @memcpy(method_buf[0..method_len], h.method[0..method_len]);
        rtype = @enumFromInt(h.rtype);
        view_id = h.view_id;
        h.* = .{};
        _ = g_wreq.outstanding.fetchSub(1, .release);
    }
    if (!verdict.cancel) {
        if (verdict.redirectUrl()) |u| {
            // Changing the url of a request held in
            // on_before_resource_load IS the redirect: CEF re-issues
            // the load at the new url when we continue.
            if (req) |r| if (r.set_url) |f| {
                var s = std.mem.zeroes(cef.cef_string_t);
                setStr(u, &s);
                defer cef.cef_string_utf16_clear(&s);
                f(r, &s);
            };
        } else {
            _ = wreqNotifyAll(.{
                .event = .send_headers,
                .url = url_buf[0..url_len],
                .method = method_buf[0..method_len],
                .rtype = rtype,
                .view_id = view_id,
            });
        }
    }
    _ = self;
    // CEF is re-entered OUTSIDE the spinlock, always; the hold's own
    // request reference can be the last one.
    if (req) |r| release(&r.base);
    if (cb) |x| {
        if (verdict.cancel) {
            if (x.cancel) |f| f(x);
        } else {
            if (x.cont) |f| f(x);
        }
        release(&x.base);
    }
}

/// Drop a slot that needs no answer (an observational mailbox that
/// has been delivered). Distinct from `wreqFailOpen` only in that
/// there is nothing to continue.
pub fn wreqRetire(self: *Host, hid: u32) void {
    _ = self;
    g_wreq.acquire();
    defer g_wreq.release();
    const h = wreqFind(hid) orelse return;
    if (h.cb != null) return; // not ours to retire
    h.* = .{};
    _ = g_wreq.outstanding.fetchSub(1, .release);
}

/// A background page answered. Folds the decision into the hold's
/// verdict; a cancel answers the request at once, anything else
/// moves the chain on to the next extension.
///
/// Every path that can end a hold reaches one of exactly these:
///   - the chain ran out of extensions -> `wreqFinish`
///   - a cancel arrived                -> `wreqFinish`, here
///   - an extension missed its deadline or became unreachable
///                                     -> the chain moves past it
///   - the extension was disabled, removed or reparsed
///                                     -> `wreqAbandonExt`
///   - its background page or the requesting view was destroyed
///                                     -> `wreqAbandonView`
///   - the helper is shutting down     -> `webrequestDeinit`
/// Anything added later that can make a listener unreachable MUST
/// reach one of these. A hold that is never answered is a page that
/// never finishes loading, with no error and no way out.
pub fn wreqDecision(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", hid: u32 = 0, g: u32 = 0, d: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
    const hid = parsed.value.hid;
    const gen = parsed.value.g;

    // Take our OWN reference to the request before dropping the
    // lock: an abandon (extension removed, view destroyed) racing
    // us would otherwise release the last one while we are still
    // calling set_header on it.
    var req: ?*cef.cef_request_t = null;
    var event: webrequest.Event = .before_request;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        const h = wreqFind(hid) orelse return;
        const st = wstatIdx(h.ext) orelse return;
        if (h.bg_view != v.id or !std.mem.eql(u8, st.idSlice(), e.id)) return;
        if (!h.dispatched or !h.cur_blocking or h.gen != gen or h.cb == null) return;
        req = h.req;
        event = h.event;
        if (req) |r| if (r.base.add_ref) |ar| ar(&r.base);
    }
    defer if (req) |r| release(&r.base);

    var dec_buf: std.Io.Writer.Allocating = .init(self.gpa);
    defer dec_buf.deinit();
    std.json.Stringify.value(parsed.value.d, .{}, &dec_buf.writer) catch return;
    const hdr_key: []const u8 = switch (event) {
        .before_send_headers => "requestHeaders",
        else => "",
    };
    var dp = webrequest.parseDecision(self.gpa, dec_buf.written(), hdr_key) catch return;
    defer dp.deinit(self.gpa);
    var d = dp.decision;
    // MV2: only onBeforeRequest may redirect.
    if (event != .before_request) d.redirect = null;
    // `SKETERM_WEB_WREQ_DEBUG=1` prints every decision with the url
    // it applies to. Finding out WHY a real extension blocked
    // something is otherwise guesswork: the verdict is computed in
    // another process, inside minified extension code.
    if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) {
        var url_buf: [512]u8 = undefined;
        var url: []const u8 = "";
        if (req) |r| {
            if (r.get_url) |gu| url = userfreeInto(gu(r), &url_buf);
        }
        std.debug.print("wreq[{d}] {s} {s} {s} -> {s}\n", .{
            hid, e.id, event.toStr(), url, dec_buf.written(),
        });
    }

    var outcome = false;
    var apply_headers = false;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        const h = wreqFind(hid) orelse return; // abandoned meanwhile
        if (h.gen != gen) return;
        const res = h.verdict.fold(d);
        if (wstatIdx(h.ext)) |s| {
            if (d.cancel) s.cancelled +%= 1;
            if (d.redirect != null and !h.verdict.cancel) s.redirected +%= 1;
            const us = nowUs() - h.start_us;
            s.note(@intCast(std.math.clamp(us, 0, std.math.maxInt(u32))));
            if (res == .apply_headers and d.headers.?.len != 0) s.headers_modified +%= 1;
        }
        outcome = res == .done;
        apply_headers = res == .apply_headers;
        if (!outcome) {
            h.advance = true;
            h.dispatched = false;
        }
    }
    if (apply_headers) {
        if (req) |r| if (r.set_header_by_name) |seth| {
            for (d.headers.?) |ed| {
                var nk = std.mem.zeroes(cef.cef_string_t);
                var nv = std.mem.zeroes(cef.cef_string_t);
                setStr(ed.name, &nk);
                defer cef.cef_string_utf16_clear(&nk);
                if (ed.value.len != 0) setStr(ed.value, &nv);
                defer cef.cef_string_utf16_clear(&nv);
                // An empty value REMOVES the header: MV2 expresses
                // a deletion by omitting it from the returned array,
                // and the JS side turns that omission into an
                // empty-valued entry.
                seth(r, &nk, if (ed.value.len != 0) &nv else null, 1);
            }
        };
    }
    if (outcome) self.wreqFinish(hid) else wreqPoke();
}
/// Report per-extension blocking-webRequest counters (0xB4 -> 0xB5).
pub fn webrequestStats(self: *Host) void {
    var out: [webrequest.MAX_PUBLISHED]proto.EvWebextWreqStats = undefined;
    var ids: [webrequest.MAX_PUBLISHED][webrequest.MAX_ID]u8 = undefined;
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.stats) |*s| {
            if (!s.used) continue;
            @memcpy(ids[n][0..s.id_len], s.idSlice());
            var sorted: [WREQ_SAMPLES]u32 = undefined;
            const cnt = @min(s.nsamples, WREQ_SAMPLES);
            @memcpy(sorted[0..cnt], s.samples[0..cnt]);
            std.mem.sort(u32, sorted[0..cnt], {}, std.sort.asc(u32));
            out[n] = .{
                .id = ids[n][0..s.id_len],
                .matched = s.matched,
                .held = s.held,
                .cancelled = s.cancelled,
                .redirected = s.redirected,
                .headers_modified = s.headers_modified,
                .headers_received_dropped = s.headers_received_dropped,
                .timed_out = s.timed_out,
                .failed_open = s.failed_open,
                .us_p50 = pct(sorted[0..cnt], 50),
                .us_p95 = pct(sorted[0..cnt], 95),
                .us_max = if (cnt == 0) 0 else sorted[cnt - 1],
                .samples = cnt,
            };
            n += 1;
        }
    }
    for (out[0..n]) |ev| self.post(ev);
}

/// Deliver a `storage.onChanged` payload to every live frame of the
/// extension (its content-script frames and its background).
pub fn broadcastChanged(self: *Host, e: *webexthost.Extension, changes_json: []const u8) void {
    for (self.views.items) |v| {
        if (v.browser == null or v.discarded) continue;
        // Every frame with the extension injected has its ctx; a
        // frame that never got it ignores the command harmlessly.
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-changed\",\"ext\":") catch continue;
        jsonStr(w, e.id) catch continue;
        w.writeAll(",\"cap\":") catch continue;
        jsonStr(w, &e.capability) catch continue;
        w.writeAll(",\"area\":\"local\",\"changes\":") catch continue;
        w.writeAll(changes_json) catch continue;
        w.writeByte('}') catch continue;
        self.sendScriptAllFrames(v, cmd.written());
    }
}

/// Whether a bridge payload is an `ext-*` op. The cheap prefix test
/// `onProcessMessage` uses to decide whether a SUBFRAME may be heard
/// at all, without parsing the JSON first.
pub fn payloadIsExt(self: *Host, raw: []const u8) bool {
    _ = self;
    // The payload is still NONCE-PREFIXED here — `onScriptMessage`
    // is what strips and checks it — so the test has to skip the
    // nonce first. Looking at the raw head instead silently answered
    // "not an extension message" for everything, which is how the
    // subframe half of `all_frames` stayed broken after the frames
    // were already being injected.
    if (raw.len <= host_mod.sem_secret.nonce.len) return false;
    const json = raw[host_mod.sem_secret.nonce.len..];
    // The script always emits `op` first, so this is a prefix test
    // rather than a parse: `{"op":"ext-`.
    const head = json[0..@min(json.len, 24)];
    return std.mem.indexOf(u8, head, "\"op\":\"ext-") != null;
}

// ---------------------------------------------------------------------
// Blocking webRequest: the held-request path
// ---------------------------------------------------------------------
//
// WHERE THE ROUND TRIP GOES, and why it never leaves this process:
//
//   CEF IO thread (on_before_resource_load)
//     -> hold slot + wake byte
//   helper main thread (between two poll iterations)
//     -> execute_java_script into the extension's BACKGROUND PAGE
//   that page's RENDERER process
//     -> the MV2 listener runs, returns a BlockingResponse
//   back over the nonce-authenticated bridge to the main thread
//     -> apply the decision to the cef_request_t, cont()/cancel()
//
// The background page is a hidden windowless browser THIS HELPER owns
// (View.webext_bg), so the only cross-process hop is the one Chromium
// forces on us. The GUI is not involved and no frame crosses the mux
// wire; a decision path through the client would add a socket hop and a
// GUI main-loop turn to the most latency-sensitive code in the browser.
//
// PRECEDENCE with the native engine (`filter.zig`), stated once here and
// mirrored in src/web/CLAUDE.md:
//
//   1. The native filter engine runs FIRST and its CANCEL is FINAL. An
//      extension is never consulted about a request the built-in
//      blocker already refused — there is nothing for it to un-cancel
//      (MV2 has no "uncancel"), and consulting it would put a JS round
//      trip on requests we already decided in nanoseconds.
//   2. Extensions see everything the native engine let through, in
//      registration order per extension and extension order after that.
//   3. EVERY matching extension is asked (`Host.wreqAdvance`), and the
//      answers fold with Chrome's precedence (`webrequest.Verdict`):
//      a cancel wins, then a redirect (the later one), then headers.
//   4. The per-view shield gate (`intercept_enable`) disables BOTH: a
//      user who turned blocking off for a site gets no extension
//      filtering there either, because "off" has to mean off.
//
// EVERY HELD REQUEST IS ANSWERED ON EVERY PATH. That is not a wish, it
// is the reason this table has an explicit `answer()` and only one:
// a request held forever is a page that never finishes loading, with no
// error and no way out. The exits are enumerated at `answerHold`.

/// How long a blocking listener may take before the request is let
/// through unfiltered. Firefox has no such cap (it trusts its own
/// extension process); we do, because a wedged background page here is
/// a wedged browser. 500ms is far above the measured p95 (see the
/// benchmark numbers in src/web/CLAUDE.md) and far below a user's
/// patience for a stuck load.
pub const wreq_timeout_ms_default: i64 = 500;

/// Concurrent held/queued requests. A burst past this fails OPEN —
/// requests continue unfiltered rather than queue behind a listener.
pub const MAX_HOLDS = 32;
pub const HOLD_URL_MAX = 1024;
pub const HOLD_HDR_MAX = 3072;

/// Latency samples kept per extension for the p50/p95 report.
pub const WREQ_SAMPLES = 256;

pub const Hold = struct {
    used: bool = false,
    hid: u32 = 0,
    /// Non-null only while the request is genuinely HELD. An
    /// observational slot has none and must never touch these.
    cb: ?*cef.cef_callback_t = null,
    req: ?*cef.cef_request_t = null,
    /// Index into `g_wstats` — the extension being asked.
    ext: usize = 0,
    bg_view: u32 = 0,
    /// Which MV2 event this dispatch is for. CEF gives ONE pre-flight
    /// callback for both `onBeforeRequest` and `onBeforeSendHeaders`,
    /// so a request needing both is dispatched TWICE in sequence from
    /// the same hold — which is also MV2's documented ordering.
    event: webrequest.Event = .before_request,
    /// A slot with no `cb` is a MAILBOX, not a hold: the request has
    /// already continued and this exists only to deliver an
    /// observational notification to ONE extension.
    want_request_headers: bool = false,
    /// False until the main thread has actually sent the command.
    dispatched: bool = false,
    /// A HELD request is a CHAIN over every extension whose filters
    /// match: `webrequest.slots` index of the one asked now (-1 before
    /// the first), and `advance` asks the main thread to move on to the
    /// next one (`Host.wreqAdvance`). Every matching extension is
    /// consulted, first phase then second, and the answers fold into
    /// `verdict` with Chrome's precedence.
    cursor: i8 = -1,
    advance: bool = false,
    /// The extension asked now registered a BLOCKING listener for this
    /// event; false means its dispatch is a notification and the chain
    /// moves on without waiting.
    cur_blocking: bool = false,
    /// Bumped per dispatch and echoed by the answer, so a late reply
    /// for an earlier step (a timed-out extension, the first phase) is
    /// never applied to a later one.
    gen: u32 = 0,
    verdict: webrequest.Verdict = .{},
    /// Extra `details` members for a notification (statusCode, error,
    /// …), already JSON, spliced verbatim.
    extra_len: u16 = 0,
    extra: [256]u8 = @splat(0),
    deadline_ms: i64 = 0,
    start_us: i64 = 0,
    rtype: u8 = 0,
    view_id: u32 = 0,
    url_len: u16 = 0,
    url: [HOLD_URL_MAX]u8 = @splat(0),
    method_len: u8 = 0,
    method: [8]u8 = @splat(0),
    /// A JSON array of `{name,value}` — built on the IO thread from the
    /// request's own header map, into this fixed buffer (no allocation
    /// on that thread, same rule the intercept log follows).
    hdr_len: u16 = 0,
    hdr: [HOLD_HDR_MAX]u8 = @splat(0),
    /// The listener ids whose OWN `RequestFilter` matched, for the
    /// extension and event being dispatched now (the chain rewrites
    /// them per step).
    ///
    /// Only these ids may run; see `webrequest.Need.ids` for why running
    /// the others is not a small inaccuracy but a browser that loads no
    /// pages at all.
    lids: [webrequest.MAX_MATCHED]u32 = @splat(0),
    n_lids: u8 = 0,

    fn urlSlice(self: *const Hold) []const u8 {
        return self.url[0..self.url_len];
    }
};

pub const WStat = struct {
    used: bool = false,
    id: [webrequest.MAX_ID]u8 = @splat(0),
    id_len: usize = 0,
    matched: u32 = 0,
    held: u32 = 0,
    cancelled: u32 = 0,
    redirected: u32 = 0,
    headers_modified: u32 = 0,
    headers_received_dropped: u32 = 0,
    timed_out: u32 = 0,
    failed_open: u32 = 0,
    nsamples: u32 = 0,
    widx: usize = 0,
    samples: [WREQ_SAMPLES]u32 = @splat(0),

    fn idSlice(self: *const WStat) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn note(self: *WStat, us: u32) void {
        self.samples[self.widx] = us;
        self.widx = (self.widx + 1) % WREQ_SAMPLES;
        if (self.nsamples < WREQ_SAMPLES) self.nsamples += 1;
    }
};

pub const WreqState = struct {
    lock: SpinLock = .{},
    /// Read WITHOUT the lock on the request path so a helper with no
    /// blocking extension pays one relaxed load per request.
    outstanding: std.atomic.Value(u32) = .init(0),
    next_hid: u32 = 1,
    /// Requests that found the table full and went through unasked.
    overflow: u32 = 0,
    timeout_ms: i64 = wreq_timeout_ms_default,
    holds: [MAX_HOLDS]Hold = @splat(.{}),
    stats: [webrequest.MAX_PUBLISHED]WStat = @splat(.{}),

    pub fn acquire(self: *WreqState) void {
        self.lock.lock();
    }
    pub fn release(self: *WreqState) void {
        self.lock.unlock();
    }
};

pub var g_wreq: WreqState = .{};

/// Self-pipe so the IO thread can cut the main loop's poll short the
/// instant a request is held. Without it the first hold of a page load
/// waits out whatever poll timeout was already running (5ms), which is
/// pure dead time on the critical path.
pub var g_wreq_wake: [2]c_int = .{ -1, -1 };

/// The read end for `server.zig` to poll, or -1 when the pipe could not
/// be made (the loop then falls back to its ordinary timeout).
pub fn webrequestWakeFd() c_int {
    return g_wreq_wake[0];
}

/// True while at least one request is held or queued. The loop shortens
/// its poll on this, because a held request is a stalled page.
pub fn webrequestBusy() bool {
    return g_wreq.outstanding.load(.acquire) != 0;
}

pub fn webrequestDrainWake() void {
    if (g_wreq_wake[0] < 0) return;
    var buf: [64]u8 = undefined;
    while (c.read(g_wreq_wake[0], &buf, buf.len) > 0) {}
}

pub fn wreqPoke() void {
    if (g_wreq_wake[1] < 0) return;
    const one: [1]u8 = .{1};
    _ = c.write(g_wreq_wake[1], &one, 1);
}

pub fn wreqInitPipe() void {
    if (g_wreq_wake[0] >= 0) return;
    if (c.pipe(&g_wreq_wake) != 0) {
        g_wreq_wake = .{ -1, -1 };
        return;
    }
    // Both ends non-blocking: the IO thread must never block on a full
    // pipe (a byte already there means the loop is already awake), and
    // the drain must never block on an empty one.
    for (g_wreq_wake) |fd| {
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    }
}

/// Override the fail-open deadline. Used by the benchmark and the smoke
/// rig; `SKETERM_WEB_WREQ_TIMEOUT_MS=<n>` is the operator-facing form.
pub fn wreqReadTimeoutEnv() void {
    const v = c.getenv("SKETERM_WEB_WREQ_TIMEOUT_MS") orelse return;
    const s = std.mem.span(v);
    const n = std.fmt.parseInt(i64, s, 10) catch return;
    if (n > 0) g_wreq.timeout_ms = n;
}

pub fn wstatFor(id: []const u8) ?*WStat {
    for (&g_wreq.stats) |*s| {
        if (s.used and std.mem.eql(u8, s.idSlice(), id)) return s;
    }
    for (&g_wreq.stats) |*s| {
        if (s.used) continue;
        if (id.len > s.id.len) return null;
        s.* = .{ .used = true };
        @memcpy(s.id[0..id.len], id);
        s.id_len = id.len;
        return s;
    }
    return null;
}

/// CEF's resource type as the MV2 `ResourceType` the filters speak.
pub fn wreqTypeOf(t: cef.cef_resource_type_t) webrequest.RType {
    return switch (t) {
        cef.RT_MAIN_FRAME => .main_frame,
        cef.RT_SUB_FRAME => .sub_frame,
        cef.RT_STYLESHEET => .stylesheet,
        cef.RT_SCRIPT => .script,
        cef.RT_IMAGE => .image,
        cef.RT_FAVICON => .image,
        cef.RT_FONT_RESOURCE => .font,
        cef.RT_XHR => .xmlhttprequest,
        cef.RT_MEDIA => .media,
        cef.RT_PING => .ping,
        cef.RT_CSP_REPORT => .csp_report,
        cef.RT_OBJECT => .object,
        else => .other,
    };
}

/// Serialize a request's or a response's headers into `out` as a JSON
/// array. IO THREAD: CEF allocates the multimap, we allocate nothing.
pub fn headerMapJson(owner: anytype, out: []u8) u16 {
    const gh = owner.*.get_header_map orelse return 0;
    const map = cef.cef_string_multimap_alloc() orelse return 0;
    defer cef.cef_string_multimap_free(map);
    gh(owner, map);
    var w = std.Io.Writer.fixed(out);
    w.writeByte('[') catch return 0;
    const n = cef.cef_string_multimap_size(map);
    var i: usize = 0;
    var first = true;
    while (i < n) : (i += 1) {
        var key = std.mem.zeroes(cef.cef_string_t);
        var val = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&key);
        defer cef.cef_string_utf16_clear(&val);
        if (cef.cef_string_multimap_key(map, i, &key) == 0) continue;
        _ = cef.cef_string_multimap_value(map, i, &val);
        var kbuf: [256]u8 = undefined;
        var vbuf: [1024]u8 = undefined;
        const ks = utf16Into(&key, &kbuf);
        const vs = utf16Into(&val, &vbuf);
        if (!first) w.writeByte(',') catch break;
        first = false;
        w.writeAll("{\"name\":") catch break;
        jsonStr(&w, ks) catch break;
        w.writeAll(",\"value\":") catch break;
        jsonStr(&w, vs) catch break;
        w.writeByte('}') catch break;
    }
    w.writeByte(']') catch return 0;
    return @intCast(w.end);
}

/// A `cef_string_t`'s UTF-8 into `buf` (truncated). Unlike
/// `userfreeInto` this does NOT take ownership.
pub fn utf16Into(s: *const cef.cef_string_t, buf: []u8) []const u8 {
    if (s.str == null or s.length == 0) return "";
    var u = Utf8.init(@constCast(s));
    defer u.free();
    const src = u.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// IO THREAD. Decide whether this request needs any extension at all,
/// and if so whether it must be HELD.
///
/// Returns true when the caller must return `RV_CONTINUE_ASYNC` — the
/// request is now this table's responsibility and WILL be answered.
///
/// EVERY extension whose filters match is consulted. A request no
/// extension blocks on is a set of per-extension MAILBOX drops and is
/// never held. A request any extension blocks on becomes ONE hold whose
/// chain the main thread walks (`Host.wreqAdvance`): each matching
/// extension in `webrequest.slots` order, `onBeforeRequest` first, then
/// `onBeforeSendHeaders`, the answers folded by `webrequest.Verdict`
/// (cancel > redirect > header edits, Chrome's precedence). Sequential
/// rather than parallel on purpose: an extension's `onBeforeSendHeaders`
/// must see the headers the one before it wrote, and the cost is one
/// round trip per extension that actually blocks on this url.
///
/// LOCK ORDER: `webrequest.lock` (the registry) is taken and RELEASED
/// before `g_wreq.lock` (the hold table). They are never nested, in
/// either direction, anywhere.
pub fn wreqConsider(
    req: *cef.cef_request_t,
    cb: ?*cef.cef_callback_t,
    url: []const u8,
    method: []const u8,
    rtype: webrequest.RType,
    view_id: u32,
) bool {
    // THE fast path: one relaxed load. A helper with no extension
    // listener at all, which is the overwhelmingly common case, pays
    // exactly this and nothing else.
    if (!webrequest.any_listeners.load(.acquire)) return false;

    var any_blocking = false;
    var any_match = false;
    var want_hdr = false;
    {
        webrequest.acquire();
        defer webrequest.release();
        for (&webrequest.slots) |*s| {
            if (!s.used) continue;
            const reg = s.reg orelse continue;
            const nb = webrequest.needFor(reg, .before_request, url, rtype);
            const ns = webrequest.needFor(reg, .before_send_headers, url, rtype);
            if (nb.isNone() and ns.isNone()) continue;
            any_match = true;
            // An extension with no background page cannot be asked: it
            // does not make the request wait (an enumerated exit).
            if (s.bg_view != 0 and (nb.blocking or ns.blocking)) any_blocking = true;
            if (nb.want_request_headers or ns.want_request_headers) want_hdr = true;
        }
    }
    if (!any_match) return false;

    // Header collection costs a CEF multimap walk; only pay for it when
    // a matching listener asked for requestHeaders.
    var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
    var hdr_len: u16 = 0;
    if (want_hdr) hdr_len = headerMapJson(req, &hdr_buf);

    if (!any_blocking) {
        inline for (.{ webrequest.Event.before_request, webrequest.Event.before_send_headers, webrequest.Event.send_headers }) |ev| {
            _ = wreqNotifyAll(.{
                .event = ev,
                .url = url,
                .method = method,
                .rtype = rtype,
                .view_id = view_id,
                .hdr = hdr_buf[0..hdr_len],
            });
        }
        return false;
    }

    g_wreq.acquire();
    var slot: ?*Hold = null;
    for (&g_wreq.holds) |*h| {
        if (!h.used) {
            slot = h;
            break;
        }
    }
    const h = slot orelse {
        // Table full. Fail OPEN: a burst of requests must not queue
        // behind a listener, and dropping the notification is strictly
        // better than stalling the page.
        g_wreq.overflow +%= 1;
        g_wreq.release();
        return false;
    };
    h.* = .{
        .used = true,
        .hid = g_wreq.next_hid,
        .view_id = view_id,
        .rtype = @intFromEnum(rtype),
        .start_us = nowUs(),
        .deadline_ms = nowMs() + g_wreq.timeout_ms,
        .hdr_len = hdr_len,
        .event = .before_request,
        .cursor = -1,
        // The main thread picks the first extension.
        .advance = true,
        // The hold KEEPS the references the callback received with
        // `cb` and `req` (the caller releases them only when this
        // returns false), so no add_ref: one would never be paid back.
        .cb = cb,
        .req = req,
    };
    g_wreq.next_hid +%= 1;
    if (g_wreq.next_hid == 0) g_wreq.next_hid = 1;
    h.url_len = @intCast(@min(url.len, h.url.len));
    @memcpy(h.url[0..h.url_len], url[0..h.url_len]);
    h.method_len = @intCast(@min(method.len, h.method.len));
    @memcpy(h.method[0..h.method_len], method[0..h.method_len]);
    if (hdr_len != 0) @memcpy(h.hdr[0..hdr_len], hdr_buf[0..hdr_len]);
    _ = g_wreq.outstanding.fetchAdd(1, .release);
    g_wreq.release();
    wreqPoke();
    return true;
}

/// One webRequest NOTIFICATION, as the request path saw it.
pub const Notice = struct {
    event: webrequest.Event,
    url: []const u8,
    method: []const u8 = "",
    rtype: webrequest.RType,
    view_id: u32,
    /// Request headers, or RESPONSE headers for a response event.
    hdr: []const u8 = "",
    /// Extra `details` members, already JSON (`"statusCode":200`).
    extra: []const u8 = "",
};

/// Queue one mailbox drop per extension whose filter matches `n`.
/// Never holds anything: the request has continued (or cannot be
/// paused at all, on the response path). Safe from the IO thread and
/// the main thread alike. Returns how many were queued.
pub fn wreqNotifyAll(n: Notice) usize {
    if (!webrequest.any_listeners.load(.acquire)) return 0;
    const Hit = struct {
        id: [webrequest.MAX_ID]u8,
        id_len: usize,
        bg_view: u32,
        need: webrequest.Need,
    };
    var hits: [webrequest.MAX_PUBLISHED]Hit = undefined;
    var nhits: usize = 0;
    {
        webrequest.acquire();
        defer webrequest.release();
        for (&webrequest.slots) |*s| {
            if (!s.used or s.bg_view == 0) continue;
            const reg = s.reg orelse continue;
            const need = webrequest.needFor(reg, n.event, n.url, n.rtype);
            if (need.isNone()) continue;
            hits[nhits] = .{ .id = undefined, .id_len = s.id_len, .bg_view = s.bg_view, .need = need };
            @memcpy(hits[nhits].id[0..s.id_len], s.idSlice());
            nhits += 1;
        }
    }
    if (nhits == 0) return 0;
    var queued: usize = 0;
    g_wreq.acquire();
    defer g_wreq.release();
    for (hits[0..nhits]) |*hit| {
        const st = wstatFor(hit.id[0..hit.id_len]);
        if (st) |s| {
            s.matched +%= 1;
            // Counted at the only moment we know a listener will be told
            // about headers it cannot change.
            if (n.event == .headers_received) s.headers_received_dropped +%= 1;
        }
        var slot: ?*Hold = null;
        for (&g_wreq.holds) |*h| {
            if (!h.used) {
                slot = h;
                break;
            }
        }
        const h = slot orelse {
            g_wreq.overflow +%= 1;
            break;
        };
        h.* = .{
            .used = true,
            .hid = g_wreq.next_hid,
            .ext = if (st) |s| (@intFromPtr(s) - @intFromPtr(&g_wreq.stats[0])) / @sizeOf(WStat) else 0,
            .bg_view = hit.bg_view,
            .event = n.event,
            .view_id = n.view_id,
            .rtype = @intFromEnum(n.rtype),
            .start_us = nowUs(),
            .deadline_ms = nowMs() + g_wreq.timeout_ms,
            .want_request_headers = n.hdr.len != 0 and
                (hit.need.want_request_headers or hit.need.want_response_headers or n.event == .headers_received),
        };
        setHoldLids(h, &hit.need);
        g_wreq.next_hid +%= 1;
        if (g_wreq.next_hid == 0) g_wreq.next_hid = 1;
        h.url_len = @intCast(@min(n.url.len, h.url.len));
        @memcpy(h.url[0..h.url_len], n.url[0..h.url_len]);
        h.method_len = @intCast(@min(n.method.len, h.method.len));
        @memcpy(h.method[0..h.method_len], n.method[0..h.method_len]);
        if (h.want_request_headers) {
            h.hdr_len = @intCast(@min(n.hdr.len, h.hdr.len));
            @memcpy(h.hdr[0..h.hdr_len], n.hdr[0..h.hdr_len]);
        }
        h.extra_len = @intCast(@min(n.extra.len, h.extra.len));
        @memcpy(h.extra[0..h.extra_len], n.extra[0..h.extra_len]);
        _ = g_wreq.outstanding.fetchAdd(1, .release);
        queued += 1;
    }
    if (queued != 0) wreqPoke();
    return queued;
}

pub fn setHoldLids(h: *Hold, need: *const webrequest.Need) void {
    h.n_lids = need.n_ids;
    @memcpy(h.lids[0..need.n_ids], need.idSlice());
}
/// Answer every hold belonging to one extension. Main thread.
pub fn wreqAbandonExt(ext_id: []const u8) void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        var want: ?usize = null;
        for (&g_wreq.stats, 0..) |*st, i| {
            if (st.used and std.mem.eql(u8, st.idSlice(), ext_id)) {
                want = i;
                break;
            }
        }
        const target = want orelse return;
        for (&g_wreq.holds) |*h| {
            if (!h.used or h.ext != target) continue;
            if (h.cb != null) {
                if (wstatIdx(target)) |st| st.failed_open +%= 1;
            }
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
    }
    // CEF is re-entered OUTSIDE the spinlock, always.
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
}

/// The `p`-th percentile of an ASCENDING slice (nearest-rank).
pub fn pct(sorted: []const u32, p: usize) u32 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * p + 99) / 100;
    const idx = @min(if (rank == 0) 0 else rank - 1, sorted.len - 1);
    return sorted[idx];
}

/// The hold with this id, or null when it has already been answered.
/// Caller holds `g_wreq.lock`.
pub fn wreqFind(hid: u32) ?*Hold {
    for (&g_wreq.holds) |*h| {
        if (h.used and h.hid == hid) return h;
    }
    return null;
}

pub fn wstatIdx(i: usize) ?*WStat {
    if (i >= g_wreq.stats.len) return null;
    return &g_wreq.stats[i];
}

/// Answer every hold whose background page or page view is `view`.
pub fn wreqAbandonView(view: u32) void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.holds) |*h| {
            if (!h.used) continue;
            if (h.bg_view != view and h.view_id != view) continue;
            if (h.cb != null) {
                if (wstatIdx(h.ext)) |s| s.failed_open +%= 1;
            }
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
    }
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
}

/// Free the pipe and answer anything still held. Helper shutdown.
pub fn webrequestDeinit() void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.holds) |*h| {
            if (!h.used) continue;
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
        }
        g_wreq.outstanding.store(0, .release);
    }
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
    for (&g_wreq_wake) |*fd| {
        if (fd.* >= 0) _ = c.close(fd.*);
        fd.* = -1;
    }
}

pub fn onGetResourceRequestHandler(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    _: c_int,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: [*c]c_int,
) callconv(.c) [*c]cef.cef_resource_request_handler_t {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    return &host_mod.resource_request_handler;
}

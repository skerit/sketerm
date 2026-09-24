//! Response-body capture (0x8B block, capability "capture"), the CEF
//! half. The filter and the bounded store are `web/capture.zig` (pure,
//! unit-tested in both roots); this module is how the engine feeds it:
//!
//!   on_before_resource_load (intercept.zig)  remember a matching request
//!                                           under the log seq it got
//!   get_resource_response_filter (here)     the response began: mime
//!                                           test, headers, request body,
//!                                           and a pass-through filter
//!   the filter's `filter` callback (here)   every body chunk, copied
//!   on_resource_load_complete (intercept)   the exchange finished
//!
//! and how the client reads it back (`capture_set`, `capture_list_req`,
//! `capture_body_req`, all on the main thread). Nothing is pushed: the
//! client pulls, the MCP backlog rule.
//!
//! The filter never changes a byte the page receives. It exists only
//! for the requests the capture filter already matched, so a view
//! without a capture, and every request a capture does not match, runs
//! exactly as before.

const std = @import("std");
const cef = @import("cef");
const capture = @import("../capture.zig");
const clock = @import("../../util/clock.zig");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const icpt = @import("intercept.zig");
const Host = host_mod.Host;
const HeapRef = host_mod.HeapRef;
const Utf8 = host_mod.Utf8;
const jsonStr = host_mod.jsonStr;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const userfreeInto = icpt.userfreeInto;

/// The store's allocator: the IO thread allocates body chunks from it
/// and whichever thread drops the last reference frees through it.
const cap_gpa = std.heap.c_allocator;

/// Serialized response headers kept per exchange; a longer header set is
/// cut at a whole header and flagged.
const HEADERS_MAX = 64 * 1024;

// -- main thread: the client's verbs --------------------------------

/// Install, clear or disable a view's capture. An install finds or
/// creates the view's intercept slot, so it may precede the
/// `view_create*` naming the view; when no slot is free the refusal is
/// an unsolicited `capture_list` with state `refused` (the client
/// counts views and refuses first, this is the belt).
pub fn captureSet(self: *Host, req: proto.CaptureSet) void {
    switch (@as(proto.CaptureOp, @enumFromInt(req.op))) {
        .install => {
            const store = capture.Store.create(cap_gpa, req) catch {
                self.post(stateOnly(req.view, req.serial, .refused));
                return;
            };
            const s = icpt.interceptSlotFor(self.gpa, req.view) orelse {
                store.release();
                self.post(stateOnly(req.view, req.serial, .refused));
                return;
            };
            var old: ?*capture.Store = null;
            {
                icpt.g_int.acquire();
                defer icpt.g_int.release();
                old = s.cap;
                s.cap = store;
            }
            if (old) |o| o.release();
        },
        .clear => {
            const store = storeOf(req.view) orelse return;
            defer store.release();
            _ = store.clear(req.upto);
        },
        .disable => {
            const store = storeOf(req.view) orelse return;
            defer store.release();
            store.disable();
        },
        _ => {},
    }
}

/// The view's capture with a reference, or null. MAIN thread.
fn storeOf(view: u32) ?*capture.Store {
    icpt.g_int.acquire();
    defer icpt.g_int.release();
    for (&icpt.g_int.slots) |*s| {
        if (!s.used or s.view_id != view) continue;
        const cs = s.cap orelse return null;
        return cs.retain();
    }
    return null;
}

fn stateOnly(view: u32, serial: u32, state: proto.CaptureState) proto.CaptureList {
    return .{
        .view = view,
        .serial = serial,
        .state = @intFromEnum(state),
        .more = 0,
        .max_body = 0,
        .max_total = 0,
        .stored = 0,
        .in_flight = 0,
        .next_cursor = 0,
        .head_cursor = 0,
        .dropped = @splat(0),
        .entries = &.{},
    };
}

/// Largest capture_list payload this helper frames; past it the page is
/// cut short with `more` set, so a page of huge urls still frames.
const LIST_FRAME_BUDGET: usize = 8 * 1024 * 1024;

/// Answer a metadata page. Always answered, `state = none` for a view
/// without a capture.
pub fn captureList(self: *Host, req: proto.CaptureListReq) void {
    const store = storeOf(req.view) orelse {
        self.post(stateOnly(req.view, 0, .none));
        return;
    };
    defer store.release();
    const scratch = cap_gpa.alloc(capture.Listed, capture.MAX_ENTRIES) catch {
        self.post(stateOnly(req.view, store.serial, .none));
        return;
    };
    defer cap_gpa.free(scratch);
    const max: usize = if (req.max == 0) 100 else req.max;
    var out = store.listWith(scratch, req.since, max, req.flags & proto.CaptureListReq.flag_in_flight != 0);
    // Keep the frame under its cap: a long url is Text and can be huge.
    var budget: usize = 0;
    var keep: usize = 0;
    var last_done: u32 = req.since;
    for (out.entries) |e| {
        const size = 96 + e.method.len + e.mime.len + e.charset.len + e.url.s.len;
        if (keep > 0 and budget + size > LIST_FRAME_BUDGET) break;
        budget += size;
        keep += 1;
        if (e.cursor != 0) last_done = e.cursor;
    }
    if (keep < out.entries.len) {
        // Cut inside the finished part: page on from the last one kept.
        if (out.entries[keep].cursor != 0) {
            out.more = true;
            out.next_cursor = last_done;
        }
        out.entries = out.entries[0..keep];
    }
    self.post(proto.CaptureList{
        .view = req.view,
        .serial = store.serial,
        .state = @intFromEnum(out.state),
        .more = @intFromBool(out.more),
        .max_body = store.filter.max_body,
        .max_total = store.filter.max_total,
        .stored = out.stored,
        .in_flight = out.in_flight,
        .next_cursor = out.next_cursor,
        .head_cursor = out.head_cursor,
        .dropped = out.dropped,
        .entries = out.entries,
    });
}

/// Answer one body chunk. Always answered, `found = 0` when the
/// exchange is not held.
pub fn captureBody(self: *Host, req: proto.CaptureBodyReq) void {
    var reply = proto.CaptureBody{
        .view = req.view,
        .seq = req.seq,
        .part = req.part,
        .found = 0,
        .complete = 0,
        .trunc = 0,
        .total = 0,
        .seen = 0,
        .offset = req.offset,
        .status = 0,
        .mime = "",
        .charset = "",
        .headers = .{ .s = "" },
        .data = .{ .s = "" },
    };
    const store = storeOf(req.view) orelse {
        self.post(reply);
        return;
    };
    defer store.release();
    const want: usize = @min(if (req.max == 0) proto.MAX_CAPTURE_CHUNK else req.max, proto.MAX_CAPTURE_CHUNK);
    const buf = cap_gpa.alloc(u8, want) catch {
        self.post(reply);
        return;
    };
    defer cap_gpa.free(buf);
    const part: proto.CapturePart = @enumFromInt(req.part);
    const r = store.readBody(req.seq, part, req.offset, buf);
    reply.found = @intFromBool(r.found);
    reply.complete = @intFromBool(r.complete);
    reply.trunc = @intFromEnum(r.trunc);
    reply.total = r.total;
    reply.seen = r.seen;
    reply.status = r.status;
    reply.mime = r.mime;
    reply.charset = r.charset;
    reply.data = .{ .s = buf[0..r.len] };
    if (part == .response and req.offset == 0) reply.headers = .{ .s = r.headers };
    self.post(reply);
}

// -- IO thread: the engine's side ----------------------------------

/// A pass-through `cef_response_filter_t` copying what flows through it
/// into one captured exchange. Owns a store reference, so a capture
/// replaced or a view destroyed mid-body never frees memory under it;
/// bytes for an exchange that was cleared meanwhile are simply passed
/// on and not kept.
const RespFilter = struct {
    filter: cef.cef_response_filter_t,
    refs: std.atomic.Value(u32) = .init(1),
    store: *capture.Store,
    uid: u64,
    hint: usize = capture.MAX_ENTRIES,

    /// The engine's last reference went: the stream is over, which is
    /// one of the two halves `Store.settle` waits for.
    pub fn destroyOwned(self: *RespFilter) void {
        self.store.streamDone(self.uid, &self.hint, clock.nowMs());
        self.store.release();
        cap_gpa.destroy(self);
    }
};
const FilterRef = HeapRef(RespFilter, "filter");

fn filterOf(self: [*c]cef.cef_response_filter_t) *RespFilter {
    return FilterRef.owner(@ptrCast(self));
}

fn onInitFilter(_: [*c]cef.cef_response_filter_t) callconv(.c) c_int {
    return 1;
}

/// Copy input to output unchanged and keep a copy. Only as much input
/// is consumed as fits the output; the engine calls again with the rest.
fn onFilter(
    self: [*c]cef.cef_response_filter_t,
    data_in: ?*anyopaque,
    data_in_size: usize,
    data_in_read: [*c]usize,
    data_out: ?*anyopaque,
    data_out_size: usize,
    data_out_written: [*c]usize,
) callconv(.c) cef.cef_response_filter_status_t {
    const n = @min(data_in_size, data_out_size);
    data_in_read.* = n;
    data_out_written.* = n;
    if (n == 0) return cef.RESPONSE_FILTER_DONE;
    const src: [*]const u8 = @ptrCast(data_in.?);
    const dst: [*]u8 = @ptrCast(data_out.?);
    @memcpy(dst[0..n], src[0..n]);
    const f = filterOf(self);
    f.store.appendBody(f.uid, &f.hint, src[0..n]);
    return cef.RESPONSE_FILTER_DONE;
}

/// IO THREAD. The response to a request the capture remembered began:
/// record it when its mime type matches, and hand the engine a filter
/// that keeps its body. Every other response gets no filter at all.
pub fn onGetResourceResponseFilter(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
) callconv(.c) [*c]cef.cef_response_filter_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const b: *cef.cef_browser_t = browser orelse return null;
    const req: *cef.cef_request_t = request orelse return null;
    const resp: *cef.cef_response_t = response orelse return null;
    const gi = b.get_identifier orelse return null;
    const store = icpt.captureOf(gi(b)) orelse return null;
    // Given to the filter on success, released on every other path.
    var keep_store = false;
    defer if (!keep_store) store.release();
    const gid = req.get_identifier orelse return null;
    const req_id = gid(req);

    var url_buf: [8192]u8 = undefined;
    const url = if (req.get_url) |gu| userfreeInto(gu(req), &url_buf) else "";
    var method_buf: [16]u8 = undefined;
    const method = if (req.get_method) |gm| userfreeInto(gm(req), &method_buf) else "";
    var mime_buf: [256]u8 = undefined;
    const mime = if (resp.get_mime_type) |gm| userfreeInto(gm(resp), &mime_buf) else "";
    var cs_buf: [64]u8 = undefined;
    const charset = if (resp.get_charset) |gc| userfreeInto(gc(resp), &cs_buf) else "";
    const status: u16 = if (resp.get_status) |gs| @intCast(std.math.clamp(gs(resp), 0, 999)) else 0;

    // The mime type is the last clause of the filter: nothing of an
    // exchange it refuses is read, let alone buffered.
    if (!store.filter.matchMime(mime)) {
        store.forget(req_id);
        return null;
    }
    var headers: std.Io.Writer.Allocating = .init(cap_gpa);
    defer headers.deinit();
    const headers_cut = writeHeaders(&headers.writer, resp);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(cap_gpa);
    const rb = requestBody(req, &body, store.filter.max_body);

    const uid = store.beginResponse(req_id, .{
        .url = url,
        .method = method,
        .mime = mime,
        .charset = charset,
        .status = status,
        .headers = headers.written(),
        .headers_truncated = headers_cut,
        .req_body = body.items,
        .req_total = rb.total,
        .req_nonbytes = rb.nonbytes,
    }, clock.wallMs(), clock.nowMs()) orelse return null;

    const f = cap_gpa.create(RespFilter) catch {
        // No filter, so no stream will ever end it: end it now, with the
        // body it has (none), rather than leave it in flight forever.
        var hint: usize = capture.MAX_ENTRIES;
        store.streamDone(uid, &hint, clock.nowMs());
        return null;
    };
    f.* = .{
        .filter = std.mem.zeroes(cef.cef_response_filter_t),
        .store = store,
        .uid = uid,
    };
    f.filter.base = FilterRef.base();
    f.filter.init_filter = onInitFilter;
    f.filter.filter = onFilter;
    keep_store = true;
    // The engine takes the reference `f` was born with.
    return &f.filter;
}

/// The response's headers as `[{"name":..,"value":..}]`, whole headers
/// only. Returns true when the set was cut at `HEADERS_MAX`.
fn writeHeaders(w: *std.Io.Writer, resp: *cef.cef_response_t) bool {
    w.writeByte('[') catch return true;
    const gh = resp.get_header_map orelse {
        w.writeByte(']') catch {};
        return false;
    };
    const map = cef.cef_string_multimap_alloc() orelse {
        w.writeByte(']') catch {};
        return true;
    };
    defer cef.cef_string_multimap_free(map);
    gh(resp, map);
    const n = cef.cef_string_multimap_size(map);
    var cut = false;
    var used: usize = 1;
    var first = true;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key = std.mem.zeroes(cef.cef_string_t);
        var val = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&key);
        defer cef.cef_string_utf16_clear(&val);
        if (cef.cef_string_multimap_key(map, i, &key) == 0) continue;
        _ = cef.cef_string_multimap_value(map, i, &val);
        var k = Utf8.init(&key);
        defer k.free();
        var v = Utf8.init(&val);
        defer v.free();
        // Escaping can at most sextuple a byte; a header that might not
        // fit is left out whole rather than cut in the middle.
        const worst = 24 + 6 * (k.slice().len + v.slice().len);
        if (used + worst + 1 > HEADERS_MAX) {
            cut = true;
            break;
        }
        const before = w.end;
        if (!first) w.writeByte(',') catch return true;
        first = false;
        w.writeAll("{\"name\":") catch return true;
        jsonStr(w, k.slice()) catch return true;
        w.writeAll(",\"value\":") catch return true;
        jsonStr(w, v.slice()) catch return true;
        w.writeByte('}') catch return true;
        used += w.end - before;
    }
    w.writeByte(']') catch return true;
    return cut;
}

const ReqBody = struct {
    /// Byte length of every byte part, kept or not.
    total: u64 = 0,
    /// Parts that are not bytes (a file upload), or parts the engine
    /// withheld from this object.
    nonbytes: bool = false,
};

/// Concatenate the request's byte parts into `out`, keeping at most
/// `cap` bytes; the rest is only counted in `total`.
fn requestBody(req: *cef.cef_request_t, out: *std.ArrayList(u8), cap: u32) ReqBody {
    var r = ReqBody{};
    const gpd = req.get_post_data orelse return r;
    const pd: *cef.cef_post_data_t = gpd(req) orelse return r;
    defer release(&pd.base);
    if (pd.has_excluded_elements) |he| r.nonbytes = he(pd) != 0;
    const gc = pd.get_element_count orelse return r;
    const count = gc(pd);
    if (count == 0) return r;
    const ge = pd.get_elements orelse return r;
    var elems: [64][*c]cef.cef_post_data_element_t = @splat(null);
    var got: usize = @min(count, elems.len);
    if (count > elems.len) r.nonbytes = true;
    ge(pd, &got, @ptrCast(&elems));
    for (elems[0..@min(got, elems.len)]) |raw| {
        const el: *cef.cef_post_data_element_t = raw orelse continue;
        defer release(&el.base);
        const gt = el.get_type orelse continue;
        const kind = gt(el);
        if (kind != cef.PDE_TYPE_BYTES) {
            if (kind != cef.PDE_TYPE_EMPTY) r.nonbytes = true;
            continue;
        }
        const gbc = el.get_bytes_count orelse continue;
        const gb = el.get_bytes orelse continue;
        const len = gbc(el);
        r.total += len;
        const take = @min(len, @as(usize, cap) -| out.items.len);
        if (take == 0) continue;
        const start = out.items.len;
        out.resize(cap_gpa, start + take) catch {
            r.nonbytes = true;
            continue;
        };
        const wrote = gb(el, take, out.items.ptr + start);
        out.shrinkRetainingCapacity(start + @min(wrote, take));
    }
    return r;
}

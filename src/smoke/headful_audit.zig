//! The headful audit: the checks public bot detectors run, as our own page
//! (`headful_audit.html` + `headful_audit.js`), the reference values stock
//! Chromium reported headful on this kind of host
//! (`headful_audit_reference.json`), and THE classification of every check
//! id (`TABLE`). smoke-mcp's audit stage serves the page from `Server`,
//! drives it through the MCP web tools and fails on any `must_match` check
//! that differs from the reference; an id missing from `TABLE` fails closed.

const std = @import("std");
const reflect = @import("../util/reflect.zig");
const c = @import("../c.zig").c;
const tcpserver = @import("tcpserver.zig");
const SpinLock = @import("../util/spinlock.zig").SpinLock;

pub const HTML = @embedFile("headful_audit.html");
pub const JS = @embedFile("headful_audit.js");
pub const REFERENCE = @embedFile("headful_audit_reference.json");

pub const Class = enum {
    /// A difference from real Chrome is a bug: the stage fails.
    must_match,
    /// Depends on the host (hardware, desktop settings, installed voices): reported only.
    host,
    /// An honest, documented difference: reported only, `why` says why.
    accepted,
};

pub const Entry = struct {
    id: []const u8,
    class: Class,
    why: []const u8 = "",
    /// The class for a `motion:"replay"` input round, where it differs
    /// from the direct click's (human-shaped input is replay's job).
    replay: ?Class = null,

    pub fn classFor(e: Entry, round: Round) Class {
        return if (round == .replay) e.replay orelse e.class else e.class;
    }
};

const M = Class.must_match;
const H = Class.host;
const A = Class.accepted;

/// Every check the page reports, classified. A page check absent here
/// fails the stage (fail closed); an entry the page stopped reporting fails
/// it too, so the table and the page cannot drift apart.
pub const TABLE = [_]Entry{
    // automation markers
    .{ .id = "auto.webdriver_value", .class = M },
    .{ .id = "auto.webdriver_where", .class = M },
    .{ .id = "auto.webdriver_write", .class = M },
    .{ .id = "auto.globals", .class = M },
    .{ .id = "auto.window_keys", .class = M },
    .{ .id = "auto.document_keys", .class = M },
    .{ .id = "auto.chrome_shape", .class = M },
    .{ .id = "auto.chrome_functions", .class = M },
    .{ .id = "auto.eval_len", .class = M },
    .{ .id = "auto.error_stack", .class = M },
    .{ .id = "auto.cdp_stack_getter", .class = M },
    // native-code / lie checks
    .{ .id = "lie.native_scan", .class = M },
    .{ .id = "lie.native_scan_cross_realm", .class = M },
    .{ .id = "lie.tostring_self", .class = M },
    .{ .id = "lie.tostring_proxy", .class = M },
    .{ .id = "lie.getter_shape", .class = M },
    .{ .id = "lie.own_props", .class = M },
    .{ .id = "lie.proto_chain", .class = M },
    // context consistency
    .{ .id = "ctx.worker", .class = M },
    .{ .id = "ctx.iframe", .class = M },
    .{ .id = "ctx.headers", .class = M },
    .{ .id = "ctx.hdr_ua", .class = M },
    .{ .id = "ctx.hdr_lang", .class = M },
    .{ .id = "ctx.hdr_client_hints", .class = M },
    .{ .id = "ctx.hdr_order_doc", .class = M },
    .{ .id = "ctx.hdr_order_frame", .class = M },
    .{ .id = "ctx.hdr_order_worker", .class = M },
    .{ .id = "ctx.hdr_order_script", .class = M },
    .{ .id = "ctx.hdr_order_fetch", .class = M },
    .{ .id = "ctx.hdr_fetch_meta_doc", .class = M },
    // window / screen geometry
    .{ .id = "geo.screen_is_viewport", .class = M },
    .{ .id = "geo.outer_exceeds_inner", .class = M },
    .{ .id = "geo.window_fits_screen", .class = M },
    .{ .id = "geo.avail_within_screen", .class = M },
    // The MCP lane synthesizes its window at Chrome's own 10,10
    // (`screengeom.headless`), so the position is a fact, not the host's.
    .{ .id = "geo.window_at_origin", .class = M },
    .{ .id = "geo.dpr", .class = H, .why = "the output's scale" },
    .{ .id = "geo.color_depth", .class = M },
    .{ .id = "geo.orientation", .class = M },
    .{ .id = "geo.screen_extended", .class = M },
    .{ .id = "geo.visual_viewport", .class = M },
    // media queries
    .{ .id = "mq.pointer", .class = M },
    .{ .id = "mq.hover", .class = M },
    .{ .id = "mq.any-pointer", .class = M },
    .{ .id = "mq.any-hover", .class = M },
    .{ .id = "mq.color-gamut", .class = M },
    .{ .id = "mq.dynamic-range", .class = M },
    .{ .id = "mq.video-dynamic-range", .class = M },
    .{ .id = "mq.prefers-color-scheme", .class = H, .why = "the desktop's colour-scheme setting" },
    .{ .id = "mq.prefers-reduced-motion", .class = H, .why = "the desktop's animation setting" },
    .{ .id = "mq.prefers-contrast", .class = H, .why = "the desktop's contrast setting" },
    .{ .id = "mq.prefers-reduced-transparency", .class = H, .why = "the desktop's transparency setting" },
    .{ .id = "mq.prefers-reduced-data", .class = M },
    .{ .id = "mq.forced-colors", .class = M },
    .{ .id = "mq.inverted-colors", .class = M },
    .{ .id = "mq.display-mode", .class = M },
    .{ .id = "mq.scripting", .class = M },
    .{ .id = "mq.update", .class = M },
    .{ .id = "mq.overflow-block", .class = M },
    .{ .id = "mq.monochrome", .class = M },
    // focus, visibility, frame pacing
    .{ .id = "focus.has_focus", .class = H, .why = "whether the compositor gave the window keyboard focus before any input; input.has_focus is the gated one" },
    .{ .id = "focus.visibility", .class = M },
    .{ .id = "focus.raf_interval", .class = M },
    // devtools-detector equivalents
    .{ .id = "dt.table_vs_log", .class = M },
    .{ .id = "dt.debugger_stall", .class = M },
    .{ .id = "dt.lazy_getters", .class = M },
    // permissions
    .{ .id = "perm.notifications", .class = M },
    .{ .id = "perm.states", .class = M },
    // graphics and media
    .{ .id = "gfx.webgl", .class = A, .why = "GPU-less host: `auto` offers SwiftShader where Chrome blocklists WebGL (Jelle, 2026-10-12: WebGL pages must keep working); `hardware` matches" },
    .{ .id = "gfx.webgl2", .class = A, .why = "follows gfx.webgl" },
    .{ .id = "gfx.webgl_params", .class = H, .why = "the GPU (or SwiftShader) limits" },
    .{ .id = "gfx.webgpu", .class = H, .why = "whether the host has a WebGPU adapter" },
    .{ .id = "gfx.canvas_stable", .class = M },
    .{ .id = "gfx.canvas_hash", .class = H, .why = "fonts and rasteriser of the host" },
    .{ .id = "gfx.canvas_pixels", .class = M },
    .{ .id = "audio.state", .class = M },
    .{ .id = "audio.sample_rate", .class = H, .why = "the audio output device" },
    .{ .id = "audio.channels", .class = H, .why = "the audio output device" },
    .{ .id = "audio.context", .class = M },
    .{ .id = "audio.offline_stable", .class = M },
    .{ .id = "audio.offline_sum", .class = H, .why = "CPU float path of the host" },
    .{ .id = "media.voices", .class = H, .why = "installed speech-dispatcher voices (none on the reference host)" },
    .{ .id = "media.devices", .class = H, .why = "the host's audio/video devices" },
    .{ .id = "media.codecs_open", .class = M },
    .{ .id = "media.codecs_proprietary", .class = A, .why = "CEF's binary distribution is built without H.264/AAC (licensing); distro Chromium carries them, so this needs a custom CEF build" },
    .{ .id = "media.clearkey", .class = M },
    .{ .id = "media.widevine", .class = H, .why = "whether a Widevine CDM is installed" },
    .{ .id = "kbd.layout_map", .class = M },
    // navigator surface
    .{ .id = "nav.plugins", .class = M },
    .{ .id = "nav.plugin_names", .class = M },
    .{ .id = "nav.static", .class = M },
    .{ .id = "nav.language_consistent", .class = M },
    .{ .id = "nav.languages", .class = H, .why = "the user's locale" },
    .{ .id = "nav.hardware", .class = H, .why = "CPU count and memory of the host" },
    .{ .id = "nav.platform", .class = H, .why = "the host's OS and architecture" },
    .{ .id = "nav.connection", .class = H, .why = "network estimate" },
    .{ .id = "nav.features", .class = M },
    .{ .id = "win.features", .class = M },
    .{ .id = "nav.storage_quota", .class = M },
    .{ .id = "nav.storage_persisted", .class = M },
    .{ .id = "nav.battery", .class = H, .why = "the host's battery (none: charging at 1)" },
    .{ .id = "intl.timezone", .class = H, .why = "the host's timezone" },
    .{ .id = "intl.offset_consistent", .class = M },
    .{ .id = "intl.locales", .class = H, .why = "the user's locale" },
    .{ .id = "uach.brands", .class = M },
    .{ .id = "uach.ua_string", .class = M },
    .{ .id = "uach.high_entropy", .class = M },
    .{ .id = "js.engine", .class = M },
    .{ .id = "meta.fact_keys", .class = M },
    // input trust (one round per click)
    .{ .id = "input.trusted", .class = M },
    .{ .id = "input.sequence", .class = M },
    .{ .id = "input.mouse_compat", .class = M },
    .{ .id = "input.has_focus", .class = M },
    .{ .id = "input.moves_before_down", .class = A, .why = "a direct web_act moves once then presses (documented); motion:replay is the human-shaped path, and the reference click (app_click) itself sends only enter+motion" },
    .{ .id = "input.hold", .class = A, .replay = M, .why = "a direct web_act presses and releases within a few ms (documented); a replayed click must hold like a person" },
    .{ .id = "input.timestamps_monotonic", .class = M },
    .{ .id = "input.pointer_props", .class = M },
    .{ .id = "input.click_props", .class = M },
    // Synthesized from this reference: window 10,10 plus the viewport's
    // 16,97 inside it (`screengeom.headless_view_offset`).
    .{ .id = "input.screen_offset", .class = M },
};

pub fn classOf(id: []const u8) ?Entry {
    for (TABLE) |e| if (std.mem.eql(u8, e.id, id)) return e;
    return null;
}

/// Which page phase reports a check: the input round ids carry the prefix.
pub const Phase = enum {
    passive,
    input,

    pub fn of(id: []const u8) Phase {
        return if (std.mem.startsWith(u8, id, "input.")) .input else .passive;
    }
};

/// One page result being judged: the passive checks, or an input round
/// clicked directly or with recorded-motion replay.
pub const Round = enum {
    passive,
    direct,
    replay,

    pub fn phase(r: Round) Phase {
        return if (r == .passive) .passive else .input;
    }
};

pub const Verdict = enum { match, differs, no_reference, absent, unclassified };

pub const Row = struct {
    id: []const u8,
    class: ?Class,
    ours: []const u8,
    ref: []const u8,
    verdict: Verdict,

    pub fn fails(r: Row) bool {
        if (r.verdict == .unclassified) return true;
        return r.class == .must_match and r.verdict != .match;
    }
};

fn jsonText(arena: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.written();
}

/// One page result (`{"phase", "checks":[{id, value, ...}]}`) against the
/// reference's section for that phase, one row per check id seen on
/// either side.
pub fn compare(arena: std.mem.Allocator, round: Round, result_body: []const u8, reference: []const u8) ![]Row {
    const phase = round.phase();
    const ours = try std.json.parseFromSliceLeaky(std.json.Value, arena, result_body, .{});
    const ref = try std.json.parseFromSliceLeaky(std.json.Value, arena, reference, .{});
    const ref_section = ref.object.get(@tagName(phase)) orelse return error.ReferenceLacksPhase;
    var rows: std.ArrayList(Row) = .empty;
    const checks = (ours.object.get("checks") orelse return error.ResultLacksChecks).array.items;
    for (checks) |ch| {
        const id = ch.object.get("id").?.string;
        const value = ch.object.get("value") orelse .null;
        const entry = classOf(id);
        const ours_text = try jsonText(arena, value);
        const ref_text: ?[]const u8 = if (ref_section.object.get(id)) |rv| try jsonText(arena, rv) else null;
        const verdict: Verdict = if (entry == null) .unclassified else if (ref_text == null) .no_reference else if (std.mem.eql(u8, ours_text, ref_text.?)) .match else .differs;
        try rows.append(arena, .{ .id = id, .class = if (entry) |e| e.classFor(round) else null, .ours = ours_text, .ref = ref_text orelse "(none)", .verdict = verdict });
    }
    for (TABLE) |e| {
        if (Phase.of(e.id) != phase) continue;
        const seen = for (rows.items) |r| {
            if (std.mem.eql(u8, r.id, e.id)) break true;
        } else false;
        if (seen) continue;
        const ref_text: []const u8 = if (ref_section.object.get(e.id)) |rv| try jsonText(arena, rv) else "(none)";
        try rows.append(arena, .{ .id = e.id, .class = e.classFor(round), .ours = "(absent)", .ref = ref_text, .verdict = .absent });
    }
    return rows.items;
}

/// Rows that fail the stage.
pub fn failures(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.fails());
    return n;
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len <= n) s else s[0..n];
}

/// The readable table on stderr: check, ours, reference, class, verdict.
pub fn printTable(label: []const u8, rows: []const Row) void {
    std.debug.print("headful audit [{s}]\n  {s:<30} {s:<11} {s:<10} {s:<44} {s}\n", .{ label, "check", "class", "verdict", "sketerm", "reference" });
    for (rows) |r| {
        const class = if (r.class) |cl| @tagName(cl) else "UNCLASSIFIED";
        const verdict = if (r.fails()) "FAIL" else switch (r.verdict) {
            .match => "ok",
            else => "differs",
        };
        std.debug.print("  {s:<30} {s:<11} {s:<10} {s:<44} {s}\n", .{ r.id, class, verdict, clip(r.ours, 120), clip(r.ref, 120) });
    }
    std.debug.print("headful audit [{s}]: {d} checks, {d} failing\n", .{ label, rows.len, failures(rows) });
}

/// The reference file from one passive and one input result: id -> value
/// per phase, plus the capture notes (a JSON object) verbatim.
pub fn buildReference(arena: std.mem.Allocator, notes_json: []const u8, passive_body: []const u8, input_body: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\n  \"notes\": ");
    try w.writeAll(notes_json);
    for ([_]struct { []const u8, []const u8 }{ .{ "passive", passive_body }, .{ "input", input_body } }) |sec| {
        try w.print(",\n  \"{s}\": {{", .{sec[0]});
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, sec[1], .{});
        for (body.object.get("checks").?.array.items, 0..) |ch, i| {
            try w.writeAll(if (i == 0) "\n    " else ",\n    ");
            try std.json.Stringify.value(ch.object.get("id").?.string, .{}, w);
            try w.writeAll(": ");
            try std.json.Stringify.value(ch.object.get("value") orelse .null, .{}, w);
        }
        try w.writeAll("\n  }");
    }
    try w.writeAll("\n}\n");
    return aw.written();
}

/// The requests whose headers the page compares, keyed by how they reach
/// the server; `/headers` reports each by its tag name.
const Slot = enum { doc, frame, worker, script, fetch };

/// The loopback server the page talks to: `/` and `/frame` (the page),
/// `/audit.js` (page, frame and Worker script), `/headers` (the request
/// headers it saw per `Slot`, its own request included) and `POST
/// /result`. Results are kept until `reset`.
pub const Server = struct {
    lis: tcpserver.Listener = .{ .backlog = 32, .poll_ms = 100 },
    allocator: std.mem.Allocator,
    lock: SpinLock = .init,
    /// Raw header blocks (after the request line), per `Slot`.
    hdr: [reflect.fields(Slot).len]?[]u8 = @splat(null),
    passive: ?[]u8 = null,
    inputs: std.ArrayList([]u8) = .empty,

    pub fn start(self: *Server) bool {
        return self.lis.start(self, &onConn);
    }

    pub fn port(self: *const Server) u16 {
        return self.lis.port;
    }

    pub fn reset(self: *Server) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.hdr) |*h| if (h.*) |b| {
            self.allocator.free(b);
            h.* = null;
        };
        if (self.passive) |p| self.allocator.free(p);
        self.passive = null;
        for (self.inputs.items) |b| self.allocator.free(b);
        self.inputs.clearRetainingCapacity();
    }

    pub fn deinit(self: *Server) void {
        self.lis.deinit();
        self.reset();
        self.inputs.deinit(self.allocator);
    }

    /// A copy of the passive result once the page posted it.
    pub fn passiveCopy(self: *Server, arena: std.mem.Allocator) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const p = self.passive orelse return null;
        return arena.dupe(u8, p) catch null;
    }

    /// A copy of the `n`th input round (0-based) once the page posted it.
    pub fn inputCopy(self: *Server, arena: std.mem.Allocator, n: usize) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        if (n >= self.inputs.items.len) return null;
        return arena.dupe(u8, self.inputs.items[n]) catch null;
    }

    const MAX_REQUEST = 4 << 20;

    fn onConn(ctx: ?*anyopaque, afd: c_int) bool {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        const req = readFull(self.allocator, afd) orelse return false;
        defer self.allocator.free(req);
        const head_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return false;
        var parts = std.mem.splitScalar(u8, req[0..line_end], ' ');
        const method = parts.next() orelse return false;
        const target = parts.next() orelse return false;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const head = req[line_end + 2 .. head_end];
        const body = req[head_end + 4 ..];
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/result")) {
            self.storeResult(body);
            tcpserver.respondOk(afd, "text/plain", "ok", "");
        } else if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/frame")) {
            self.storeHeaders(if (path.len == 1) .doc else .frame, head);
            tcpserver.respondOk(afd, "text/html; charset=utf-8", HTML, "");
        } else if (std.mem.eql(u8, path, "/audit.js")) {
            const worker = if (headerValue(head, "sec-fetch-dest")) |d| std.mem.eql(u8, d, "worker") else false;
            self.storeHeaders(if (worker) .worker else .script, head);
            tcpserver.respondOk(afd, "text/javascript; charset=utf-8", JS, "");
        } else if (std.mem.eql(u8, path, "/headers")) {
            self.storeHeaders(.fetch, head);
            const json = self.headersJson() orelse return false;
            defer self.allocator.free(json);
            tcpserver.respondOk(afd, "application/json", json, "");
        } else {
            tcpserver.respond(afd, "404 Not Found", "text/plain", "", "");
        }
        return false;
    }

    fn storeResult(self: *Server, body: []const u8) void {
        const copy = self.allocator.dupe(u8, body) catch return;
        const is_input = std.mem.indexOf(u8, body[0..@min(body.len, 40)], "\"phase\":\"input\"") != null;
        self.lock.lock();
        defer self.lock.unlock();
        if (is_input) {
            self.inputs.append(self.allocator, copy) catch self.allocator.free(copy);
        } else {
            if (self.passive) |p| self.allocator.free(p);
            self.passive = copy;
        }
    }

    fn storeHeaders(self: *Server, slot: Slot, head: []const u8) void {
        const copy = self.allocator.dupe(u8, head) catch return;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.hdr[@intFromEnum(slot)]) |old| self.allocator.free(old);
        self.hdr[@intFromEnum(slot)] = copy;
    }

    fn headersJson(self: *Server) ?[]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &aw.writer;
        writeHeaders(w, self.hdr) catch {
            aw.deinit();
            return null;
        };
        return aw.toOwnedSlice() catch null;
    }

    fn writeHeaders(w: *std.Io.Writer, hdr: anytype) !void {
        try w.writeByte('{');
        for (hdr, 0..) |block, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{s}\":[", .{@tagName(@as(Slot, @enumFromInt(i)))});
            if (block) |b| {
                var lines = std.mem.splitSequence(u8, b, "\r\n");
                var first = true;
                while (lines.next()) |ln| {
                    const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeByte('[');
                    try std.json.Stringify.value(ln[0..colon], .{}, w);
                    try w.writeByte(',');
                    try std.json.Stringify.value(std.mem.trim(u8, ln[colon + 1 ..], " \t"), .{}, w);
                    try w.writeByte(']');
                }
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }

    /// The whole request: the header block plus a Content-Length body.
    fn readFull(allocator: std.mem.Allocator, afd: c_int) ?[]u8 {
        var buf: std.ArrayList(u8) = .empty;
        var want: ?usize = null;
        while (buf.items.len < MAX_REQUEST) {
            if (want == null) {
                if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |end| {
                    const len = if (headerValue(buf.items[0..end], "content-length")) |v| std.fmt.parseInt(usize, v, 10) catch 0 else 0;
                    want = end + 4 + len;
                }
            }
            if (want) |n| if (buf.items.len >= n) return buf.toOwnedSlice(allocator) catch null;
            var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 5000) <= 0) break;
            var tmp: [65536]u8 = undefined;
            const n = c.read(afd, &tmp, tmp.len);
            if (n <= 0) break;
            buf.appendSlice(allocator, tmp[0..@intCast(n)]) catch break;
        }
        if (want != null and buf.items.len >= want.?) return buf.toOwnedSlice(allocator) catch null;
        buf.deinit(allocator);
        return null;
    }
};

/// A header's value, matched case-insensitively.
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |ln| {
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(ln[0..colon], name)) return std.mem.trim(u8, ln[colon + 1 ..], " \t");
    }
    return null;
}

test "every reference check is classified and every classified check has a reference" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ref = try std.json.parseFromSliceLeaky(std.json.Value, arena, REFERENCE, .{});
    for ([_]Phase{ .passive, .input }) |phase| {
        var it = ref.object.get(@tagName(phase)).?.object.iterator();
        while (it.next()) |kv| {
            const e = classOf(kv.key_ptr.*) orelse {
                std.debug.print("unclassified reference check {s}\n", .{kv.key_ptr.*});
                return error.Unclassified;
            };
            try std.testing.expectEqual(phase, Phase.of(e.id));
        }
    }
    for (TABLE, 0..) |e, i| {
        if (ref.object.get(@tagName(Phase.of(e.id))).?.object.get(e.id) == null) {
            std.debug.print("classified check {s} has no reference value\n", .{e.id});
            return error.NoReference;
        }
        if (e.class != .must_match and e.why.len == 0) {
            std.debug.print("{s} is {s} without a reason\n", .{ e.id, @tagName(e.class) });
            return error.NoReason;
        }
        for (TABLE[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, prev.id, e.id));
    }
}

test "compare: a reference replayed as a result passes, a changed must_match fails, an unknown id fails closed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ref = try std.json.parseFromSliceLeaky(std.json.Value, arena, REFERENCE, .{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"phase\":\"passive\",\"checks\":[");
    var it = ref.object.get("passive").?.object.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try aw.writer.print("{{\"id\":\"{s}\",\"value\":", .{kv.key_ptr.*});
        try std.json.Stringify.value(kv.value_ptr.*, .{}, &aw.writer);
        try aw.writer.writeByte('}');
    }
    try aw.writer.writeAll("]}");
    const same = aw.written();
    try std.testing.expectEqual(@as(usize, 0), failures(try compare(arena, .passive, same, REFERENCE)));

    const changed = try std.mem.replaceOwned(u8, arena, same, "\"id\":\"auto.eval_len\",\"value\":33", "\"id\":\"auto.eval_len\",\"value\":34");
    try std.testing.expectEqual(@as(usize, 1), failures(try compare(arena, .passive, changed, REFERENCE)));
    const unknown = try std.mem.concat(arena, u8, &.{ same[0 .. same.len - 2], ",{\"id\":\"new.check\",\"value\":1}]}" });
    try std.testing.expectEqual(@as(usize, 1), failures(try compare(arena, .passive, unknown, REFERENCE)));
    // A must_match check the page stopped reporting fails too.
    const dropped = try std.mem.replaceOwned(u8, arena, same, "\"id\":\"auto.eval_len\"", "\"id\":\"auto.eval_len_renamed\"");
    try std.testing.expectEqual(@as(usize, 2), failures(try compare(arena, .passive, dropped, REFERENCE)));
}

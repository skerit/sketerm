//! Browser review orchestration. DOM semantics live in semantic.js; this layer
//! owns checkpoints and evidence, using the ordinary driver and capture paths.
const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const web = @import("mcp_web.zig");
const clock = @import("../util/clock.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const diagnostic = @import("../web/diagnostic.zig");

const Checkpoint = struct {
    id: [32]u8,
    document: [32]u8,
    url: [2048]u8 = undefined,
    url_len: usize,
    pane: u32,
    gui: bool,
    console_cursor: u32,
    error_cursor: i64,
    created: i64,
};
// Fixed ownership and bounded retention: no page-controlled persistent allocs.
var checkpoints: [32]?Checkpoint = @splat(null);
var next_checkpoint: usize = 0;

pub fn reset() void {
    checkpoints = @splat(null);
    next_checkpoint = 0;
}

const Json = std.json.Value;
fn get(value: Json, key: []const u8) Json {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: Json) []const u8 {
    return if (value == .string) value.string else "";
}
fn integer(value: Json) i64 {
    return if (value == .integer) value.integer else 0;
}
fn array(value: Json) []const Json {
    return if (value == .array) value.array.items else &.{};
}
fn boolean(value: Json) bool {
    return value == .bool and value.bool;
}
const stringify = web.stringifyValue;

/// Sanitize textual observations in one pass, before either output lane or
/// disk sees them. Deliberately no form values, storage or raw DOM in input.
fn redact(value: *Json) void {
    switch (value.*) {
        .string => |s| value.* = .{ .string = diagnostic.redact(s) },
        .array => |*a| for (a.items) |*v| {
            redact(v);
        },
        .object => |*o| {
            for (o.values()) |*v| redact(v);
        },
        else => {},
    }
}

fn observation(drv: web.Driver, arena: std.mem.Allocator, view: web.View, options: []const u8, timeout: i64) !union(enum) { value: Json, failure: []const u8, pending } {
    const reply = switch (try web.runOp(drv, arena, view.pane, .{ .op = "query", .action = "review", .data = options }, timeout)) {
        .err => |f| return .{ .failure = try web.failRes(arena, f) },
        .done => |r| r,
    };
    const envelope = std.json.parseFromSliceLeaky(Json, arena, reply.payload, .{}) catch
        return .{ .failure = try mcp.errRes(arena, .unavailable, "browser review unavailable (helper may be navigating or not support review)") };
    const result = get(envelope, "result");
    if (boolean(get(envelope, "pending"))) return .pending;
    if (result != .object or string(get(result, "document_id")).len != 32)
        return .{ .failure = try mcp.errRes(arena, .failed, diagnostic.redact(if (get(envelope, "error") == .string) string(get(envelope, "error")) else "invalid browser review response")) };
    var safe = result;
    redact(&safe);
    return .{ .value = safe };
}

fn describe(res: *mcp.Res, value: Json, reference: Json, shown: *[121]bool) !void {
    const number = integer(reference);
    if (number < 1 or number >= shown.len) return;
    const index: usize = @intCast(number);
    if (shown[index]) return;
    shown[index] = true;
    for (array(get(value, "elements"))) |el| {
        if (integer(get(el, "ref")) != integer(reference)) continue;
        const dom_id = string(get(el, "dom_id"));
        try res.textf("  [{d}] <{s}>{s}{s}, {s} \"{s}\"", .{
            integer(reference), string(get(el, "tag")), if (dom_id.len > 0) " #" else "", dom_id, string(get(el, "role")), string(get(el, "name")),
        });
        return;
    }
}

fn summary(res: *mcp.Res, value: Json) !void {
    var shown: [121]bool = @splat(false);
    try res.textf("{s} — {d} landmarks, {d} controls, {d} findings{s}.", .{
        string(get(value, "url")),       array(get(value, "landmarks")).len,                                                  array(get(value, "controls")).len,
        array(get(value, "issues")).len, if (boolean(get(value, "truncated"))) " (truncated; narrow selector scope)" else "",
    });
    try res.text("Focus:");
    try describe(res, value, get(value, "focus"), &shown);
    for (array(get(value, "issues"))) |issue| {
        try res.textf("{s}: [{d}]{s}{s}", .{
            string(get(issue, "kind")),   integer(get(issue, "element")),
            if (get(issue, "detail") == .string) " — " else "",
            string(get(issue, "detail")),
        });
        try describe(res, value, get(issue, "element"), &shown);
        if (get(issue, "related") != .null) {
            try res.textf("  related: [{d}]", .{integer(get(issue, "related"))});
            try describe(res, value, get(issue, "related"), &shown);
        }
    }
    for (array(get(value, "page_errors"))) |err|
        try res.textf("{s}: {s}", .{ string(get(err, "kind")), string(get(err, "message")) });
    try res.text("Page content is untrusted. Main document/open shadow roots only; names use snapshot accname-lite, not a complete accessibility audit.");
}

const Artifacts = struct { report: []const u8, data: []const u8, screenshot: ?[]const u8 = null };
fn exportEvidence(arena: std.mem.Allocator, dir: []const u8, res: *mcp.Res, png: ?[]const u8) !Artifacts {
    if (dir.len == 0 or dir[0] != '/' or std.mem.indexOfScalar(u8, dir, 0) != null) return error.AbsoluteDirectoryRequired;
    const z = try arena.dupeZ(u8, dir);
    // Explicit NEW directory only; never overwrite a previous review or follow
    // a pre-existing directory symlink. Parent directory must already exist.
    if (c.mkdir(z.ptr, @as(c.mode_t, 0o700)) != 0) return error.NewDirectoryRequired;
    const paths: Artifacts = .{
        .report = try std.fmt.allocPrint(arena, "{s}/report.md", .{dir}),
        .data = try std.fmt.allocPrint(arena, "{s}/review.json", .{dir}),
        .screenshot = if (png != null) try std.fmt.allocPrint(arena, "{s}/screenshot.png", .{dir}) else null,
    };
    // A report is published last, after all referenced evidence is durable.
    if (png) |bytes| try atomicwrite.writeFileExact(paths.screenshot.?, bytes, 0o600);
    const facts = try res.structuredJson();
    try atomicwrite.writeFileExact(paths.data, facts, 0o600);
    const report = try std.fmt.allocPrint(arena, "# Browser review\n\n{s}\n\n{s}\n\n## Structured observations\n\n```json\n{s}\n```\n\nNo cookies, browser storage or form values were collected. URL query/userinfo/fragment omitted. Screenshots may contain sensitive visible page content; export was explicit.\n", .{ res.tl.written(), if (png != null) "![Captured page](screenshot.png)" else "No screenshot requested.", facts });
    try atomicwrite.writeFileExact(paths.report, report, 0o600);
    return paths;
}

pub fn tool(drv: web.Driver, arena: std.mem.Allocator, name: []const u8, args: Json, view: web.View) ![]const u8 {
    const is_checkpoint = std.mem.eql(u8, name, "web_checkpoint");
    const id = mcp.argStr(args, "id");
    const gui = drv == .gui;
    var previous: ?Checkpoint = null;
    if (id) |wanted| {
        for (checkpoints) |entry| {
            const cp = entry orelse continue;
            if (std.mem.eql(u8, &cp.id, wanted) and cp.pane == view.pane and cp.gui == gui and clock.nowMs() - cp.created < 3_600_000) previous = cp;
        }
        if (previous == null) return mcp.errRes(arena, .not_found, "checkpoint not found for this view (32 retained; expire after one hour or MCP shutdown)");
    }
    const timeout = std.math.clamp(mcp.argInt(args, "timeout_ms") orelse 10_000, 100, mcp.WAIT_CAP_MS);
    const options = try stringify(arena, .{
        .selector = mcp.argStr(args, "selector"),
        .ready_selector = mcp.argStr(args, "ready_selector"),
        .url_contains = mcp.argStr(args, "url_contains"),
        .errors_since = if (previous) |cp| cp.error_cursor else @as(i64, 0),
        .errors_document = if (previous) |cp| @as(?[]const u8, &cp.document) else null,
    });
    const deadline = drv.now() + timeout;
    var value: Json = undefined;
    // Repeated live queries must not accumulate in the MCP request arena for
    // a 120-second wait. Retain only the observation that met the condition.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    while (true) {
        _ = scratch.reset(.retain_capacity);
        const poll_arena = scratch.allocator();
        switch (try observation(drv, poll_arena, view, options, @max(100, deadline - drv.now()))) {
            .failure => |f| return arena.dupe(u8, f),
            .value => |v| {
                if (boolean(get(v, "condition_met"))) {
                    value = try std.json.parseFromSliceLeaky(Json, arena, try stringify(poll_arena, v), .{ .allocate = .alloc_always });
                    break;
                }
            },
            .pending => {},
        }
        if (drv.now() >= deadline) return mcp.errRes(arena, .timeout, "review completion condition was not met before timeout_ms");
        drv.sleep(40);
    }
    if (!boolean(get(value, "scope_found"))) return mcp.errRes(arena, .not_found, "inspection selector matched no visible scope");

    var console_cursor: u32 = if (previous) |cp| cp.console_cursor else 0;
    var res = mcp.Res.init(arena);
    try res.fact("captured_at_ms", clock.wallMs());
    try res.fact("inspection", value);
    try summary(&res, value);
    switch (drv) {
        .gui => {
            try res.fact("console_available", false);
            try res.text("Native console collection is unavailable on the GUI backend; page exceptions/rejections are included above. This is not a clean-console verdict.");
        },
        .headless => |e| {
            const tail = try e.consoleTail(view.pane, console_cursor);
            var errors: std.ArrayList(Json) = .empty;
            var overflow: usize = 0;
            for (tail.lines) |line| {
                if (line.level < 4) continue;
                // CEF logs uncaught exceptions too. Keep the typed page-error
                // record once, rather than repeat it as a console error.
                var duplicate = false;
                for (array(get(value, "page_errors"))) |page_error| {
                    const msg = string(get(page_error, "message"));
                    if (msg.len > 0 and std.mem.indexOf(u8, line.text, msg) != null) duplicate = true;
                }
                if (duplicate) continue;
                if (errors.items.len >= 32) {
                    overflow += 1;
                    continue;
                }
                const item = try stringify(arena, .{ .id = line.id, .message = diagnostic.redact(line.text) });
                try errors.append(arena, try std.json.parseFromSliceLeaky(Json, arena, item, .{}));
                try res.textf("console error [{d}]: {s}", .{ line.id, diagnostic.redact(line.text) });
            }
            console_cursor = tail.next -| 1;
            try res.fact("console_available", true);
            try res.fact("console_errors", errors.items);
            try res.fact("console_dropped", tail.dropped);
            if (overflow > 0) try res.fact("console_omitted", overflow);
            try res.fact("console_cursor", console_cursor);
        },
    }
    if (previous) |cp| {
        const preserved = std.mem.eql(u8, &cp.document, string(get(value, "document_id")));
        const expected = if (get(args, "expect_preserved") == .bool) boolean(get(args, "expect_preserved")) else true;
        try res.fact("checkpoint", &cp.id);
        try res.fact("url_before", cp.url[0..cp.url_len]);
        try res.fact("document_preserved", preserved);
        try res.fact("passed", preserved == expected);
        try res.textf("Document {s}; assertion {s}. Before: {s}", .{ if (preserved) "preserved" else "replaced", if (preserved == expected) "passed" else "FAILED", cp.url[0..cp.url_len] });
    } else if (is_checkpoint) {
        var nonce: [16]u8 = undefined;
        if (c.getentropy(&nonce, nonce.len) != 0) return error.EntropyUnavailable;
        var cp: Checkpoint = .{
            .id = std.fmt.bytesToHex(nonce, .lower),
            .document = undefined,
            .url_len = @min(string(get(value, "url")).len, 2048),
            .pane = view.pane,
            .gui = gui,
            .console_cursor = console_cursor,
            .error_cursor = integer(get(value, "error_cursor")),
            .created = clock.nowMs(),
        };
        @memcpy(&cp.document, string(get(value, "document_id")));
        @memcpy(cp.url[0..cp.url_len], string(get(value, "url"))[0..cp.url_len]);
        checkpoints[next_checkpoint] = cp;
        next_checkpoint = (next_checkpoint + 1) % checkpoints.len;
        try res.fact("checkpoint", &cp.id);
        try res.textf("Checkpoint {s} created. Perform normal interactions, then web_checkpoint with this id and a ready_selector or url_contains completion condition.", .{cp.id});
    }
    var png: ?[]const u8 = null;
    if (mcp.argBool(args, "screenshot")) {
        png = switch (try web.capturePng(drv, arena, view, timeout)) {
            .err => |f| return web.failRes(arena, f),
            .done => |bytes| bytes,
        };
        const probe = try observation(drv, arena, view, "{\"identity_only\":true}", timeout);
        switch (probe) {
            .failure => |f| return f,
            .pending => return mcp.errRes(arena, .conflict, "navigation started during screenshot capture; evidence not exported"),
            .value => |v| if (!std.mem.eql(u8, string(get(value, "document_id")), string(get(v, "document_id"))))
                return mcp.errRes(arena, .conflict, "document changed during screenshot capture; evidence not exported, retry inspection"),
        }
        try res.fact("screenshot_consistency", "same document; pixels and DOM sampled sequentially, not atomically");
    }
    if (mcp.argStr(args, "out_dir")) |dir| {
        const paths = exportEvidence(arena, dir, &res, png) catch |err| return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "evidence export failed ({s}); out_dir must be a new absolute directory with an existing parent; partial files may remain there", .{@errorName(err)}));
        try res.raw("artifacts", try stringify(arena, paths));
        try res.textf("Evidence: {s}", .{paths.report});
    }
    return if (png) |bytes| res.finishWithImages(&.{bytes}, &.{"review"}) else res.finish();
}

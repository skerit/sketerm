//! Remote-control wire protocol: one JSON object per line, request
//! in, response out. Pure data + (de)serialization — no GTK, no
//! sockets — so it unit-tests headless.
//!
//! Requests: {"cmd":"send-text","pane":3,"data":"ls\n"}
//! Responses: {"ok":true,...} or {"ok":false,"error":"..."}

const std = @import("std");

/// Maximum accepted request line. A valid panel document may itself occupy
/// 1 MiB; wrapping that JSON as the `document` string can nearly double it.
/// Four MiB accepts the full document boundary plus request metadata while
/// keeping newline-less clients and ordinary control requests bounded.
pub const MAX_LINE = 4 << 20;

pub const Request = struct {
    cmd: []const u8 = "",
    /// Pane address. null = focused pane.
    pane: ?u32 = null,
    /// Self-pane address by STABLE session name (`$SKETERM_SESSION`),
    /// preferred over `pane` because the GUI pane id goes stale across a
    /// restart/reattach. Resolved to the pane currently rendering that
    /// session; falls back to `pane`. A given address that resolves to
    /// nothing is an error, never the current pane.
    session: ?[]const u8 = null,
    /// Tab address. null = selected tab.
    tab: ?u32 = null,
    /// send-text payload / set-title text.
    data: ?[]const u8 = null,
    /// send-text: wrap in bracketed-paste markers when the app
    /// enabled mode 2004 (mirrors interactive paste). Default raw.
    paste: bool = false,
    /// get-text: also include the last N scrollback lines. 0 = just
    /// the visible screen.
    scrollback: u32 = 0,
    /// get-text: return only the last completed command's output
    /// (OSC 133 C/D zone) plus its exit code — needs shell
    /// integration in the pane's shell.
    last_command: bool = false,
    /// split: "h" (side by side) or "v" (stacked).
    direction: ?[]const u8 = null,
    /// new-tab: working directory and title.
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// new-durable-tab / attach-session: SSH host of the mux daemon
    /// ("user@box" accepted). null = local daemon.
    host: ?[]const u8 = null,
    /// attach-session: controller-lease intent for a shared app
    /// session. Neither set = take the lease only if it is free (the
    /// default and the historical behaviour). `read_only` = view
    /// without ever driving; `control` = force a takeover.
    read_only: bool = false,
    control: bool = false,
    /// web-container: the container's views RUN on `host` (a remote
    /// helper spawned by that host's daemon) instead of `host` being an
    /// egress proxy.
    remote: bool = false,
    /// web-container: throwaway cache/cookies (the incognito shape).
    ephemeral: bool = false,
    /// web-open: open the tab inside this identity container.
    container: ?u32 = null,

    // ---- panel-* (declarative UI panels, src/ui/panel) ----------------
    /// Panel name. Panels are keyed by (session, name): showing a name
    /// that already exists in that session REPLACES its document.
    name: ?[]const u8 = null,
    /// panel-show placement: "pane" (the requesting pane wears the
    /// panel face), "tab" (a new tab in its window), "window" (a
    /// standalone panel window). Default "tab".
    target: ?[]const u8 = null,
    /// panel-show: the whole panel document, as a JSON string.
    document: ?[]const u8 = null,
    /// panel-patch: a JSON array of patch ops.
    patch: ?[]const u8 = null,
    /// panel-patch / panel-events / panel-close: the handle panel-show
    /// returned.
    panel_id: ?u32 = null,
    /// panel-events-reliable: acknowledge all previously returned events
    /// through this sequence before peeking the remaining queue.
    ack: u64 = 0,
    /// Reliable event sequence identity. Omit or send empty only for initial
    /// discovery with ack=0; retries and acknowledgements echo the epoch.
    event_epoch: ?[]const u8 = null,
    /// panel-open-session: exact target session and immutable lifetime fence.
    /// Transport and placement are derived from the relayed source Terminal.
    mux_session: ?[]const u8 = null,
    mux_origin_id: ?[]const u8 = null,
    /// Required idempotency key for panel-open-session. Safe ASCII, at most
    /// 128 bytes; retries reuse it and receive the original result.
    request_token: ?[]const u8 = null,

    // ---- web-* (browser views, src/ui/webface.zig) --------------------
    //
    // Every semantic round trip is ASYNCHRONOUS (the helper answers
    // frames later), while this socket answers a request line at once:
    // `web-request` starts one and hands back a token, `web-result`
    // polls it. The MCP side owns the deadline, exactly like
    // panel-events.
    /// web-request operation: snapshot | act | expand | query | read | eval.
    op: ?[]const u8 = null,
    /// Sub-action: web-act action, web-query kind, web-navigate action.
    action: ?[]const u8 = null,
    /// Semantic node id — web-act/web-expand target, snapshot scope.
    node: ?u32 = null,
    /// The handle web-request returned.
    token: ?u32 = null,
    /// Snapshot mode ("auto" | "full") and detail level (0|1|2).
    mode: ?[]const u8 = null,
    detail: ?u32 = null,
    /// web-expand window into a truncated node's text.
    offset: ?u32 = null,
    length: ?u32 = null,
    /// web-eval: resolve a returned promise, bounded by timeout_ms.
    await_promise: bool = false,
    timeout_ms: ?u32 = null,
    /// web-scroll wheel deltas, logical pixels, positive = right/down.
    dx: ?i32 = null,
    dy: ?i32 = null,
};

pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(Request) {
    if (line.len > MAX_LINE) return error.LineTooLong;
    return std.json.parseFromSlice(Request, allocator, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const PaneInfo = struct {
    id: u32,
    title: []const u8,
    cwd: []const u8,
    pid: i32,
    rows: u16,
    cols: u16,
    focused: bool,
    /// Pane is zoomed (fills its tab, siblings hidden).
    zoomed: bool = false,
};

pub const TabInfo = struct {
    id: u32,
    /// Id of the window holding this tab. Panes move between windows
    /// (tab drag-out), and `list` spans them all, so the tree is only
    /// unambiguous with the window named.
    window: u32 = 0,
    title: []const u8,
    selected: bool,
    /// "#rrggbb" when a tab colour is set.
    color: ?[]const u8 = null,
    /// Tab id of this tab's parent in the window's tab forest
    /// (tree-style tabs); null for a root tab.
    tree_parent: ?u32 = null,
    panes: []const PaneInfo,
};

/// One live panel, as reported by `panel-list`.
pub const PanelInfo = struct {
    panel_id: u32,
    event_epoch: []const u8,
    name: []const u8,
    session: []const u8,
    title: []const u8,
    /// "pane" | "tab" | "window".
    target: []const u8,
};

/// One queued interaction, as reported by `panel-events`. `value` is
/// null / number / bool / string depending on the component; `ts` is
/// monotonic milliseconds (ordering and deltas only, not wall time).
pub const PanelEvent = struct {
    /// Monotonic sequence assigned by the live panel queue.
    seq: u64 = 0,
    component: []const u8,
    kind: []const u8,
    value: std.json.Value,
    ts: i64,
};

/// Append a JSON response line (including trailing '\n') to `out`.
/// `payload` is any Stringify-able value merged in as a field.
pub fn writeOk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime field: ?[]const u8, payload: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (field) |f| {
        try w.writeAll("{\"ok\":true,\"");
        try w.writeAll(f);
        try w.writeAll("\":");
        try std.json.Stringify.value(payload, .{}, w);
        try w.writeAll("}\n");
    } else {
        try w.writeAll("{\"ok\":true}\n");
    }
    try out.appendSlice(allocator, aw.written());
}

/// Like `writeOk`, but MERGES the payload's fields into the top-level
/// response object instead of nesting them under a name — the reply
/// shape the panel-* commands are specified in
/// (`{"ok":true,"panel_id":3,"session":"s"}`). `payload` must
/// stringify as a JSON object; an empty one degrades to `{"ok":true}`.
pub fn writeOkFlat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, payload: anytype) !void {
    // `.{}` is an empty TUPLE, which stringifies as `[]` — the one
    // shape that cannot be merged. It means "no extra fields".
    if (@typeInfo(@TypeOf(payload)).@"struct".fields.len == 0) {
        try out.appendSlice(allocator, "{\"ok\":true}\n");
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    const body = aw.written();
    if (body.len < 2 or body[0] != '{' or body[body.len - 1] != '}') return error.NotAnObject;
    try out.appendSlice(allocator, "{\"ok\":true");
    if (body.len > 2) {
        try out.append(allocator, ',');
        try out.appendSlice(allocator, body[1 .. body.len - 1]);
    }
    try out.appendSlice(allocator, "}\n");
}

pub fn writeErr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, msg: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll("}\n");
    try out.appendSlice(allocator, aw.written());
}

pub fn writeErrCode(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code: []const u8,
    msg: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll(",\"error_code\":");
    try std.json.Stringify.value(code, .{}, w);
    try w.writeAll("}\n");
    try out.appendSlice(allocator, aw.written());
}

test "parseRequest: minimal + addressed" {
    const a = std.testing.allocator;
    var p1 = try parseRequest(a, "{\"cmd\":\"list\"}");
    defer p1.deinit();
    try std.testing.expectEqualStrings("list", p1.value.cmd);
    try std.testing.expectEqual(@as(?u32, null), p1.value.pane);

    var p2 = try parseRequest(a, "{\"cmd\":\"send-text\",\"pane\":7,\"data\":\"ls\\n\",\"paste\":true}");
    defer p2.deinit();
    try std.testing.expectEqual(@as(?u32, 7), p2.value.pane);
    try std.testing.expectEqualStrings("ls\n", p2.value.data.?);
    try std.testing.expect(p2.value.paste);
}

test "parseRequest: panel-* fields" {
    const a = std.testing.allocator;
    var p = try parseRequest(a,
        \\{"cmd":"panel-show","name":"train","session":"s1","target":"window","document":"{\"root\":\"r\"}"}
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("panel-show", p.value.cmd);
    try std.testing.expectEqualStrings("train", p.value.name.?);
    try std.testing.expectEqualStrings("s1", p.value.session.?);
    try std.testing.expectEqualStrings("window", p.value.target.?);
    try std.testing.expectEqualStrings("{\"root\":\"r\"}", p.value.document.?);

    var p2 = try parseRequest(a, "{\"cmd\":\"panel-events-reliable\",\"panel_id\":7,\"ack\":42,\"event_epoch\":\"10000000000000000000000000000001\"}");
    defer p2.deinit();
    try std.testing.expectEqual(@as(?u32, 7), p2.value.panel_id);
    try std.testing.expectEqual(@as(u64, 42), p2.value.ack);
    try std.testing.expectEqualStrings("10000000000000000000000000000001", p2.value.event_epoch.?);
}

test "writeOkFlat merges payload fields at the top level" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try writeOkFlat(&out, a, .{ .panel_id = @as(u32, 3), .session = "s1" });
    try std.testing.expectEqualStrings("{\"ok\":true,\"panel_id\":3,\"session\":\"s1\"}\n", out.items);

    // An empty payload is still a well-formed ok line.
    out.clearRetainingCapacity();
    try writeOkFlat(&out, a, .{});
    try std.testing.expectEqualStrings("{\"ok\":true}\n", out.items);

    // Panel event array shape, including a null and a string value.
    out.clearRetainingCapacity();
    const evs = [_]PanelEvent{
        .{ .seq = 1, .component = "ok", .kind = "click", .value = .null, .ts = 5 },
        .{ .seq = 2, .component = "pick", .kind = "change", .value = .{ .string = "epoch 41" }, .ts = 6 },
    };
    try writeOkFlat(&out, a, .{ .events = evs[0..], .dropped = @as(u32, 2) });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"value\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"value\":\"epoch 41\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"seq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"dropped\":2") != null);
    // NDJSON framing: the whole reply is one line.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\n"));
}

test "panel submit event serializes a 4096-byte value without truncation" {
    const a = std.testing.allocator;
    const submitted = "q" ** 4096;
    const evs = [_]PanelEvent{.{
        .component = "query",
        .kind = "submit",
        .value = .{ .string = submitted },
        .ts = 9,
    }};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeOkFlat(&out, a, .{ .events = evs[0..], .dropped = @as(u32, 0) });

    var parsed = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try std.testing.expectEqualStrings("submit", event.get("kind").?.string);
    try std.testing.expectEqualStrings(submitted, event.get("value").?.string);
}

test "parseRequest: unknown fields ignored, junk rejected" {
    const a = std.testing.allocator;
    var p = try parseRequest(a, "{\"cmd\":\"list\",\"future_field\":42}");
    defer p.deinit();
    try std.testing.expectEqualStrings("list", p.value.cmd);

    try std.testing.expectError(error.SyntaxError, parseRequest(a, "not json"));
}

test "writeOk / writeErr shapes" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try writeOk(&out, a, null, {});
    try std.testing.expectEqualStrings("{\"ok\":true}\n", out.items);

    out.clearRetainingCapacity();
    try writeOk(&out, a, "text", "hi\n");
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"hi\\n\"}\n", out.items);

    out.clearRetainingCapacity();
    try writeErr(&out, a, "no such pane");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"no such pane\"}\n", out.items);

    // Round-trip a TabInfo tree through Stringify.
    out.clearRetainingCapacity();
    const panes = [_]PaneInfo{.{ .id = 1, .title = "sh", .cwd = "/", .pid = 42, .rows = 24, .cols = 80, .focused = true }};
    const tabs = [_]TabInfo{.{ .id = 1, .title = "Tab", .selected = true, .panes = &panes }};
    try writeOk(&out, a, "tabs", tabs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"pid\":42") != null);
    // Root tabs must still EMIT tree_parent (as null): smoke-e2e's
    // structural nesting probe anchors on the key being present.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"tree_parent\":null") != null);

    out.clearRetainingCapacity();
    const child = [_]TabInfo{.{ .id = 2, .title = "Child", .selected = false, .tree_parent = 1, .panes = &panes }};
    try writeOk(&out, a, "tabs", child[0..]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"tree_parent\":1") != null);
}

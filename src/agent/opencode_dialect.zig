//! The shapes of opencode's server generations (`adapter.Dialect`): the
//! request bodies, the replies and the events of each, beside the routes
//! the adapter declares as data.
//!
//! The `opencode.Source` state machine reads ONE vocabulary, opencode
//! 1.x's (`{type, properties}` events, `{info, parts}` messages). A newer
//! dialect is translated into it here, so every rule about turns, done,
//! pending requests and records stays in one place. `v1` is the identity.
//!
//! 2.x (measured, v2.0.18): replies are wrapped in `{data}`; events are
//! `{id, created, type, data}` of an execution/step/inbox model. A prompt
//! is admitted to the session's inbox (`session.inbox.enqueued`) and
//! becomes a user message only when the loop takes it
//! (`session.inbox.delivered`); each model step is one assistant message
//! (`session.step.started` .. `ended`/`failed`), its text arrives as
//! `session.text.*` per ordinal and its tool calls as `session.tool.*`;
//! `session.execution.started` / `succeeded|failed|interrupted` bracket a
//! run. Questions are forms (`form.created`, fields with keys and option
//! values). Model, effort and agent are set on the session, never sent
//! with a prompt.

const std = @import("std");
const adapter = @import("adapter.zig");
const http = @import("http.zig");

const Value = std.json.Value;
const Dialect = adapter.Dialect;

/// A form field's type (2.x): how its answer is encoded.
pub const FieldKind = enum { string, number, integer, boolean, multiselect, external };

pub const Holes = struct {
    session: ?[]const u8 = null,
    request: ?[]const u8 = null,
    limit: ?u32 = null,
};

/// `route` (`"METHOD /path"`, validated by the adapter) with its holes
/// filled, allocated from `a`.
pub fn request(a: std.mem.Allocator, route: []const u8, holes: Holes, body: ?[]const u8) !http.Request {
    const sr = adapter.splitRoute(route) orelse return error.BadRoute;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < sr.path.len) {
        if (sr.path[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, sr.path, i, '}')) |close| {
                if (std.meta.stringToEnum(adapter.RouteHole, sr.path[i + 1 .. close])) |hole| {
                    switch (hole) {
                        .session => try out.appendSlice(a, holes.session orelse return error.NoSession),
                        .request => try out.appendSlice(a, holes.request orelse return error.NoRequest),
                        .limit => try out.print(a, "{d}", .{holes.limit orelse return error.NoLimit}),
                    }
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(a, sr.path[i]);
        i += 1;
    }
    return .{ .method = sr.method, .path = out.items, .body = body };
}

// ── replies ──────────────────────────────────────────────────────

/// What a reply answers, for `reply`.
pub const Reply = enum { session_info, messages, status, permissions, questions, models, commands };

/// A reply in the 1.x shape `Source` and `Api` read: the session object, a
/// `[{info, parts}]` list oldest first, a `{id: {type}}` status map, the
/// 1.x permission and question request lists, a `{all, connected}`
/// provider catalog, a command list.
/// @param session the session a `messages` reply belongs to (2.x messages
/// do not name it).
pub fn reply(d: Dialect, which: Reply, a: std.mem.Allocator, v: Value, session: ?[]const u8) !Value {
    if (d == .v1) return v;
    const data = get(v, "data") orelse return error.BadReply;
    return switch (which) {
        .session_info, .commands => data,
        .messages => try messagesV1(a, data, session orelse return error.NoSession),
        .status => try statusV1(a, data),
        .permissions => try mapList(a, data, permissionV1),
        .questions => try mapList(a, data, formV1),
        .models => try catalogV1(a, data),
    };
}

fn mapList(a: std.mem.Allocator, list: Value, comptime f: anytype) !Value {
    var arr = std.json.Array.init(a);
    if (list == .array) for (list.array.items) |x| if (try f(a, x)) |y| try arr.append(y);
    return .{ .array = arr };
}

fn statusV1(a: std.mem.Allocator, data: Value) !Value {
    var m: std.json.ObjectMap = .empty;
    if (data == .object) {
        var it = data.object.iterator();
        while (it.next()) |e| try m.put(a, e.key_ptr.*, try parse(a, "{\"type\":\"busy\"}"));
    }
    return .{ .object = m };
}

/// A 2.x permission request as 1.x's (`permission.asked` properties).
fn permissionV1(a: std.mem.Allocator, req: Value) !?Value {
    return try build(a, .{
        .id = str(req, "id") orelse return null,
        .sessionID = str(req, "sessionID") orelse return null,
        .permission = str(req, "action") orelse "permission",
        .patterns = get(req, "resources") orelse Value{ .array = std.json.Array.init(a) },
        .always = get(req, "save") orelse Value{ .array = std.json.Array.init(a) },
    });
}

/// A 2.x form as a 1.x question request: one question per visible field,
/// carrying the field's `key`, `kind` and option `value`s for the reply.
fn formV1(a: std.mem.Allocator, form: Value) !?Value {
    const Opt = struct { label: []const u8, value: []const u8 };
    const Q = struct { question: []const u8, header: []const u8, options: []const Opt, multiple: bool, custom: bool, key: []const u8, kind: []const u8 };
    var qs: std.ArrayList(Q) = .empty;
    const fields = get(form, "fields") orelse return null;
    if (fields != .array) return null;
    for (fields.array.items) |f| {
        if (boolean(f, "hidden") orelse false) continue;
        const key = str(f, "key") orelse continue;
        const kind = std.meta.stringToEnum(FieldKind, str(f, "type") orelse "string") orelse .external;
        var opts: std.ArrayList(Opt) = .empty;
        if (kind == .boolean) {
            try opts.appendSlice(a, &.{ .{ .label = "yes", .value = "true" }, .{ .label = "no", .value = "false" } });
        } else if (get(f, "options")) |os| if (os == .array) for (os.array.items) |o| {
            const value = str(o, "value") orelse continue;
            try opts.append(a, .{ .label = str(o, "label") orelse value, .value = value });
        };
        const title = str(f, "title") orelse "";
        try qs.append(a, .{
            .question = str(f, "description") orelse if (title.len > 0) title else key,
            .header = title,
            .options = opts.items,
            .multiple = kind == .multiselect,
            .custom = if (kind == .boolean) false else boolean(f, "custom") orelse (opts.items.len == 0),
            .key = key,
            .kind = @tagName(kind),
        });
    }
    return try build(a, .{
        .id = str(form, "id") orelse return null,
        .sessionID = str(form, "sessionID") orelse return null,
        .questions = qs.items,
    });
}

/// The enabled models of 2.x's `/api/model` as 1.x's `/provider` catalog
/// (`variants` an object of level names; the rest of each entry as is).
fn catalogV1(a: std.mem.Allocator, data: Value) !Value {
    var providers: std.json.ObjectMap = .empty;
    var order: std.ArrayList([]const u8) = .empty;
    if (data == .array) for (data.array.items) |m| {
        if (!(boolean(m, "enabled") orelse true)) continue;
        const pid = str(m, "providerID") orelse continue;
        const id = str(m, "id") orelse continue;
        const gop = try providers.getOrPut(a, pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .object = .empty };
            try order.append(a, pid);
        }
        var entry: std.json.ObjectMap = .empty;
        if (m == .object) {
            var it = m.object.iterator();
            while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "variants")) try entry.put(a, e.key_ptr.*, e.value_ptr.*);
        }
        var variants: std.json.ObjectMap = .empty;
        if (get(m, "variants")) |vs| if (vs == .array) for (vs.array.items) |x| {
            if (str(x, "id")) |vid| try variants.put(a, vid, .{ .object = .empty });
        };
        try entry.put(a, "variants", .{ .object = variants });
        try gop.value_ptr.object.put(a, id, .{ .object = entry });
    };
    var all = std.json.Array.init(a);
    var connected = std.json.Array.init(a);
    for (order.items) |pid| {
        var p: std.json.ObjectMap = .empty;
        try p.put(a, "id", .{ .string = pid });
        try p.put(a, "models", providers.get(pid).?);
        try all.append(.{ .object = p });
        try connected.append(.{ .string = pid });
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "all", .{ .array = all });
    try out.put(a, "connected", .{ .array = connected });
    return .{ .object = out };
}

/// 2.x's projected messages (any order) as 1.x's `[{info, parts}]`,
/// oldest first. Only user and assistant messages carry records; a
/// compaction's summary never does.
fn messagesV1(a: std.mem.Allocator, data: Value, session: []const u8) !Value {
    var rows: std.ArrayList(Value) = .empty;
    if (data == .array) try rows.appendSlice(a, data.array.items);
    std.sort.block(Value, rows.items, {}, struct {
        fn lt(_: void, x: Value, y: Value) bool {
            return createdOf(x) < createdOf(y);
        }
    }.lt);
    var out = std.json.Array.init(a);
    for (rows.items) |m| {
        const id = str(m, "id") orelse continue;
        const ty = str(m, "type") orelse continue;
        const tm = get(m, "time");
        const created = if (tm) |x| int(x, "created") orelse 0 else 0;
        if (std.mem.eql(u8, ty, "user")) {
            try out.append(try build(a, .{
                .info = .{ .id = id, .role = "user", .sessionID = session, .time = .{ .created = created } },
                .parts = .{try userPart(a, id, session, str(m, "text") orelse "")},
            }));
            continue;
        }
        if (!std.mem.eql(u8, ty, "assistant")) continue;
        const completed: ?i64 = if (tm) |x| int(x, "completed") else null;
        var parts = std.json.Array.init(a);
        var ordinal: u32 = 0;
        if (get(m, "content")) |content| if (content == .array) for (content.array.items) |c| {
            const cty = str(c, "type") orelse continue;
            if (std.mem.eql(u8, cty, "text")) {
                const pid = try textPartId(a, id, ordinal);
                ordinal += 1;
                const TimeEnd = struct { start: i64, end: ?i64 };
                try parts.append(try build(a, .{
                    .type = "text",
                    .id = pid,
                    .messageID = id,
                    .sessionID = session,
                    .text = str(c, "text") orelse "",
                    .time = TimeEnd{ .start = created, .end = completed },
                }));
            } else if (std.mem.eql(u8, cty, "tool")) {
                const st = get(c, "state") orelse continue;
                const status = str(st, "status") orelse continue;
                try parts.append(try toolPart(a, session, id, str(c, "id") orelse continue, str(c, "name") orelse "tool", toolStatus(status), get(st, "input"), get(st, "content"), get(st, "error")));
            }
        };
        try out.append(try build(a, .{
            .info = try assistantInfo(a, .{
                .id = id,
                .session = session,
                .created = created,
                .completed = completed,
                .model = get(m, "model"),
                .tokens = get(m, "tokens"),
                .cost = get(m, "cost"),
                .err = get(m, "error"),
            }),
            .parts = Value{ .array = parts },
        }));
    }
    return .{ .array = out };
}

fn createdOf(m: Value) i64 {
    const tm = get(m, "time") orelse return 0;
    return int(tm, "created") orelse 0;
}

/// A 2.x tool state's status as 1.x's (`streaming` is 1.x's `pending`).
fn toolStatus(s: []const u8) []const u8 {
    return if (std.mem.eql(u8, s, "streaming")) "pending" else s;
}

fn textPartId(a: std.mem.Allocator, message: []const u8, ordinal: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:t{d}", .{ message, ordinal });
}

fn userPart(a: std.mem.Allocator, message: []const u8, session: []const u8, text: []const u8) !Value {
    return build(a, .{
        .type = "text",
        .id = try std.fmt.allocPrint(a, "{s}:u", .{message}),
        .messageID = message,
        .sessionID = session,
        .text = text,
    });
}

/// The joined text of a 2.x tool result's `content`.
fn contentText(a: std.mem.Allocator, content: ?Value) ![]const u8 {
    const c = content orelse return "";
    if (c != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (c.array.items) |x| if (str(x, "text")) |t| try out.appendSlice(a, t);
    return out.items;
}

fn toolPart(a: std.mem.Allocator, session: []const u8, message: []const u8, id: []const u8, name: []const u8, status: []const u8, input: ?Value, content: ?Value, err: ?Value) !Value {
    const out = try contentText(a, content);
    const err_text: []const u8 = if (err) |e| str(e, "message") orelse "" else "";
    return build(a, .{
        .type = "tool",
        .tool = name,
        .id = id,
        .messageID = message,
        .sessionID = session,
        .state = .{
            .status = status,
            .input = input orelse Value{ .object = .empty },
            .output = out,
            .@"error" = if (err_text.len > 0) err_text else out,
        },
    });
}

const AssistantInfo = struct {
    id: []const u8,
    session: []const u8,
    created: i64,
    completed: ?i64 = null,
    model: ?Value = null,
    tokens: ?Value = null,
    cost: ?Value = null,
    err: ?Value = null,
};

/// A 1.x assistant `info`: a 2.x structured error `{type, message,
/// status}` becomes `{name, data: {message, statusCode}}`.
fn assistantInfo(a: std.mem.Allocator, i: AssistantInfo) !Value {
    var m: std.json.ObjectMap = .empty;
    try m.put(a, "id", .{ .string = i.id });
    try m.put(a, "role", .{ .string = "assistant" });
    try m.put(a, "sessionID", .{ .string = i.session });
    var tm: std.json.ObjectMap = .empty;
    try tm.put(a, "created", .{ .integer = i.created });
    if (i.completed) |c| try tm.put(a, "completed", .{ .integer = c });
    try m.put(a, "time", .{ .object = tm });
    if (i.model) |md| {
        if (str(md, "providerID")) |p| try m.put(a, "providerID", .{ .string = p });
        if (str(md, "id")) |x| try m.put(a, "modelID", .{ .string = x });
    }
    if (i.tokens) |x| try m.put(a, "tokens", x);
    if (i.cost) |x| try m.put(a, "cost", x);
    if (i.err) |e| if (e != .null) try m.put(a, "error", try errorV1(a, e));
    return .{ .object = m };
}

fn errorV1(a: std.mem.Allocator, e: Value) !Value {
    const Data = struct { message: []const u8, statusCode: ?i64 };
    return build(a, .{
        .name = str(e, "type") orelse "UnknownError",
        .data = Data{ .message = str(e, "message") orelse "", .statusCode = int(e, "status") },
    });
}

// ── events ───────────────────────────────────────────────────────

/// The 2.x events the translator reads; every other type is ignored.
const EventV2 = enum {
    @"server.connected",
    @"session.created",
    @"session.model.selected",
    @"session.execution.started",
    @"session.execution.succeeded",
    @"session.execution.failed",
    @"session.execution.interrupted",
    @"session.step.started",
    @"session.step.ended",
    @"session.step.failed",
    @"session.text.delta",
    @"session.text.ended",
    @"session.tool.input.started",
    @"session.tool.called",
    @"session.tool.success",
    @"session.tool.failed",
    @"session.retry.scheduled",
    @"session.compaction.ended",
    @"session.inbox.enqueued",
    @"session.inbox.delivered",
    @"session.inbox.cancelled",
    @"permission.asked",
    @"permission.replied",
    @"permission.rejected",
    @"form.created",
    @"form.replied",
    @"form.cancelled",
};

/// Turns a 2.x event stream into 1.x events. It keeps what a later 2.x
/// event leaves out and a 1.x one needs: a tool call's name and input, the
/// step a session is running and its model, and the text of prompts the
/// session has admitted but not taken yet.
pub const Translator = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMapUnmanaged(Tool) = .empty,
    steps: std.StringHashMapUnmanaged(Step) = .empty,
    inbox: std.StringHashMapUnmanaged(Inbox) = .empty,

    const Tool = struct { name: []u8, input: []u8 = &.{} };
    const Step = struct {
        /// The assistant message of the step running, null between steps.
        message: ?[]u8 = null,
        provider: []u8 = &.{},
        model: []u8 = &.{},
        /// A step of the current execution failed (its error is reported).
        failed: bool = false,
    };
    const Inbox = struct { session: []u8, text: []u8 };

    pub fn init(allocator: std.mem.Allocator) Translator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Translator) void {
        const a = self.allocator;
        var ti = self.tools.iterator();
        while (ti.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.name);
            a.free(e.value_ptr.input);
        }
        self.tools.deinit(a);
        var si = self.steps.iterator();
        while (si.next()) |e| {
            a.free(e.key_ptr.*);
            freeStep(a, e.value_ptr.*);
        }
        self.steps.deinit(a);
        var ii = self.inbox.iterator();
        while (ii.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.session);
            a.free(e.value_ptr.text);
        }
        self.inbox.deinit(a);
    }

    fn freeStep(a: std.mem.Allocator, s: Step) void {
        if (s.message) |m| a.free(m);
        a.free(s.provider);
        a.free(s.model);
    }

    /// Prompts `session` admitted that its loop has not taken yet (sent
    /// while it was busy, or parked by an interrupt).
    pub fn parked(self: *const Translator, session: []const u8) u32 {
        var n: u32 = 0;
        var it = self.inbox.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.session, session)) n += 1;
        }
        return n;
    }

    fn step(self: *Translator, session: []const u8) !*Step {
        const gop = try self.steps.getOrPut(self.allocator, session);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, session) catch |err| {
                self.steps.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn endStep(self: *Translator, st: *Step) void {
        if (st.message) |m| self.allocator.free(m);
        st.message = null;
    }

    /// Append the 1.x events `ev` stands for to `out` (allocated from `a`).
    /// @param root the session the agent drives (its model is noted).
    pub fn translate(self: *Translator, a: std.mem.Allocator, ev: Value, root: ?[]const u8, out: *std.ArrayList(Value)) !void {
        const kind = std.meta.stringToEnum(EventV2, str(ev, "type") orelse return) orelse return;
        const d = get(ev, "data") orelse Value{ .null = {} };
        const created = int(ev, "created") orelse 0;
        const sid = str(d, "sessionID") orelse "";
        const is_root = if (root) |r| std.mem.eql(u8, r, sid) else false;
        switch (kind) {
            .@"server.connected" => try push(a, out, "server.connected", .{}),
            .@"session.created" => if (str(d, "parentID")) |parent| {
                try push(a, out, "session.created", .{ .sessionID = sid, .info = .{ .id = sid, .parentID = parent } });
            },
            .@"session.model.selected" => if (is_root) if (get(d, "model")) |m| {
                try push(a, out, "session.updated", .{ .sessionID = sid, .info = .{ .id = sid, .model = m } });
            },
            .@"session.execution.started" => {
                (try self.step(sid)).failed = false;
                try pushStatus(a, out, sid, "busy", null);
            },
            .@"session.execution.succeeded" => try pushStatus(a, out, sid, "idle", null),
            .@"session.execution.failed" => {
                const st = try self.step(sid);
                // A failed step already reported the error on its message.
                if (!st.failed) if (get(d, "error")) |e| if (e != .null) {
                    const id = try std.fmt.allocPrint(a, "{s}:failed", .{str(ev, "id") orelse "exec"});
                    try push(a, out, "message.updated", .{ .sessionID = sid, .info = try assistantInfo(a, .{ .id = id, .session = sid, .created = created, .completed = created, .err = e }) });
                };
                try pushStatus(a, out, sid, "idle", null);
            },
            .@"session.execution.interrupted" => {
                const st = try self.step(sid);
                if (st.message) |m| {
                    const abort = try parse(a, "{\"type\":\"MessageAbortedError\",\"message\":\"interrupted\"}");
                    try push(a, out, "message.updated", .{ .sessionID = sid, .info = try assistantInfo(a, .{ .id = try a.dupe(u8, m), .session = sid, .created = created, .completed = created, .err = abort }) });
                    self.endStep(st);
                }
                try pushStatus(a, out, sid, "idle", null);
            },
            .@"session.step.started" => {
                const mid = str(d, "assistantMessageID") orelse return;
                const st = try self.step(sid);
                const owned = try self.allocator.dupe(u8, mid);
                self.endStep(st);
                st.message = owned;
                if (get(d, "model")) |m| {
                    const p = try self.allocator.dupe(u8, str(m, "providerID") orelse "");
                    errdefer self.allocator.free(p);
                    const md = try self.allocator.dupe(u8, str(m, "id") orelse "");
                    self.allocator.free(st.provider);
                    self.allocator.free(st.model);
                    st.provider = p;
                    st.model = md;
                    if (is_root) try push(a, out, "session.updated", .{ .sessionID = sid, .info = .{ .id = sid, .model = m } });
                }
                try pushStatus(a, out, sid, "busy", null);
                try push(a, out, "message.updated", .{ .sessionID = sid, .info = try assistantInfo(a, .{ .id = mid, .session = sid, .created = int(d, "started") orelse created, .model = get(d, "model") }) });
            },
            .@"session.step.ended", .@"session.step.failed" => {
                const mid = str(d, "assistantMessageID") orelse return;
                const st = try self.step(sid);
                const model = try build(a, .{ .providerID = st.provider, .id = st.model });
                if (kind == .@"session.step.failed") st.failed = true;
                try push(a, out, "message.updated", .{ .sessionID = sid, .info = try assistantInfo(a, .{
                    .id = mid,
                    .session = sid,
                    .created = created,
                    .completed = created,
                    .model = if (st.provider.len > 0) model else null,
                    .tokens = get(d, "tokens"),
                    .cost = get(d, "cost"),
                    .err = get(d, "error"),
                }) });
                if (st.message) |m| if (std.mem.eql(u8, m, mid)) self.endStep(st);
            },
            .@"session.text.delta" => {
                const mid = str(d, "assistantMessageID") orelse return;
                try push(a, out, "message.part.delta", .{
                    .sessionID = sid,
                    .messageID = mid,
                    .partID = try textPartId(a, mid, @intCast(int(d, "ordinal") orelse 0)),
                    .field = "text",
                    .delta = str(d, "delta") orelse "",
                });
            },
            .@"session.text.ended" => {
                const mid = str(d, "assistantMessageID") orelse return;
                try push(a, out, "message.part.updated", .{ .sessionID = sid, .part = .{
                    .type = "text",
                    .id = try textPartId(a, mid, @intCast(int(d, "ordinal") orelse 0)),
                    .messageID = mid,
                    .sessionID = sid,
                    .text = str(d, "text") orelse "",
                    .time = .{ .start = created, .end = created },
                } });
            },
            .@"session.tool.input.started" => {
                const id = str(d, "id") orelse return;
                if (self.tools.contains(id)) return;
                const key = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(key);
                const name = try self.allocator.dupe(u8, str(d, "name") orelse "tool");
                errdefer self.allocator.free(name);
                try self.tools.put(self.allocator, key, .{ .name = name });
            },
            .@"session.tool.called" => {
                const id = str(d, "id") orelse return;
                const input = get(d, "input") orelse Value{ .object = .empty };
                const json = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
                if (self.tools.getPtr(id)) |t| {
                    self.allocator.free(t.input);
                    t.input = json;
                } else {
                    errdefer self.allocator.free(json);
                    const key = try self.allocator.dupe(u8, id);
                    errdefer self.allocator.free(key);
                    const name = try self.allocator.dupe(u8, str(d, "name") orelse "tool");
                    errdefer self.allocator.free(name);
                    try self.tools.put(self.allocator, key, .{ .name = name, .input = json });
                }
                const t = self.tools.get(id).?;
                try push(a, out, "message.part.updated", .{ .sessionID = sid, .part = try toolPart(a, sid, str(d, "assistantMessageID") orelse "", id, t.name, "running", input, null, null) });
            },
            .@"session.tool.success", .@"session.tool.failed" => {
                const id = str(d, "id") orelse return;
                const kv = self.tools.fetchRemove(id);
                defer if (kv) |x| {
                    self.allocator.free(x.key);
                    self.allocator.free(x.value.name);
                    self.allocator.free(x.value.input);
                };
                const name = if (kv) |x| x.value.name else "tool";
                const input: ?Value = if (kv) |x| (if (x.value.input.len > 0) try std.json.parseFromSliceLeaky(Value, a, x.value.input, .{}) else null) else null;
                const status = if (kind == .@"session.tool.success") "completed" else "error";
                try push(a, out, "message.part.updated", .{ .sessionID = sid, .part = try toolPart(a, sid, str(d, "assistantMessageID") orelse "", id, name, status, input, get(d, "content"), get(d, "error")) });
            },
            .@"session.retry.scheduled" => {
                const msg = if (get(d, "error")) |e| str(e, "message") orelse "" else "";
                try pushStatus(a, out, sid, "retry", msg);
            },
            .@"session.compaction.ended" => try push(a, out, "session.compacted", .{ .sessionID = sid }),
            .@"session.inbox.enqueued" => {
                const id = str(d, "inboxID") orelse return;
                const item = get(d, "item") orelse return;
                // Only a prompt becomes a user message (a compaction or a
                // move is a control item).
                if (!std.mem.eql(u8, str(item, "type") orelse "", "user")) return;
                if (self.inbox.contains(id)) return;
                const text = if (get(item, "payload")) |p| str(p, "text") orelse "" else "";
                const key = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(key);
                const s = try self.allocator.dupe(u8, sid);
                errdefer self.allocator.free(s);
                const tx = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(tx);
                try self.inbox.put(self.allocator, key, .{ .session = s, .text = tx });
            },
            .@"session.inbox.delivered" => {
                const id = str(d, "inboxID") orelse return;
                const kv = self.inbox.fetchRemove(id) orelse return;
                defer {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.session);
                    self.allocator.free(kv.value.text);
                }
                try push(a, out, "message.updated", .{ .sessionID = sid, .info = .{ .id = id, .role = "user", .sessionID = sid, .time = .{ .created = created } } });
                try push(a, out, "message.part.updated", .{ .sessionID = sid, .part = try userPart(a, id, sid, kv.value.text) });
            },
            .@"session.inbox.cancelled" => {
                const id = str(d, "inboxID") orelse return;
                const kv = self.inbox.fetchRemove(id) orelse return;
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.session);
                self.allocator.free(kv.value.text);
            },
            .@"permission.asked" => if (try permissionV1(a, d)) |p| try pushProps(a, out, "permission.asked", p),
            .@"permission.replied", .@"permission.rejected" => {
                try push(a, out, "permission.replied", .{ .sessionID = sid, .requestID = str(d, "requestID") orelse str(d, "id") orelse return });
            },
            .@"form.created" => if (try formV1(a, get(d, "form") orelse return)) |q| try pushProps(a, out, "question.asked", q),
            .@"form.replied" => try push(a, out, "question.replied", .{ .sessionID = sid, .requestID = str(d, "id") orelse str(d, "formID") orelse return }),
            .@"form.cancelled" => try push(a, out, "question.rejected", .{ .sessionID = sid, .requestID = str(d, "id") orelse str(d, "formID") orelse return }),
        }
    }
};

fn push(a: std.mem.Allocator, out: *std.ArrayList(Value), comptime ty: []const u8, props: anytype) !void {
    try pushProps(a, out, ty, try build(a, props));
}

fn pushProps(a: std.mem.Allocator, out: *std.ArrayList(Value), ty: []const u8, props: Value) !void {
    var m: std.json.ObjectMap = .empty;
    try m.put(a, "type", .{ .string = ty });
    try m.put(a, "properties", props);
    try out.append(a, .{ .object = m });
}

fn pushStatus(a: std.mem.Allocator, out: *std.ArrayList(Value), sid: []const u8, ty: []const u8, message: ?[]const u8) !void {
    const Status = struct { type: []const u8, message: ?[]const u8 = null };
    try push(a, out, "session.status", .{ .sessionID = sid, .status = Status{ .type = ty, .message = message } });
}

// ── request bodies ───────────────────────────────────────────────

pub const ModelChoice = struct { provider: []const u8, model: []const u8, variant: ?[]const u8 = null };

/// A prompt. 1.x carries the model, effort and agent; 2.x takes them on
/// the session (`selectModelBody`/`selectAgentBody` first) and queues a
/// prompt sent while the session works for its next turn, like 1.x.
pub fn promptBody(d: Dialect, a: std.mem.Allocator, text: []const u8, model: ?ModelChoice, agent: ?[]const u8) ![]u8 {
    return switch (d) {
        .v1 => {
            const TextPart = struct { type: []const u8 = "text", text: []const u8 };
            const ModelRef = struct { providerID: []const u8, modelID: []const u8 };
            return stringify(a, .{
                .parts = [1]TextPart{.{ .text = text }},
                .model = if (model) |m| ModelRef{ .providerID = m.provider, .modelID = m.model } else null,
                .variant = if (model) |m| m.variant else null,
                .agent = agent,
            });
        },
        .v2 => stringify(a, .{ .text = text, .delivery = "queue" }),
    };
}

pub fn selectModelBody(a: std.mem.Allocator, m: ModelChoice) ![]u8 {
    const Ref = struct { providerID: []const u8, id: []const u8, variant: ?[]const u8 };
    return stringify(a, .{ .model = Ref{ .providerID = m.provider, .id = m.model, .variant = m.variant } });
}

pub fn selectAgentBody(a: std.mem.Allocator, agent: []const u8) ![]u8 {
    return stringify(a, .{ .agent = agent });
}

/// A permission reply (`once`, `always`, `reject`), with the user's
/// message to the model on a reject.
pub fn permissionBody(d: Dialect, a: std.mem.Allocator, choice: []const u8, message: ?[]const u8) ![]u8 {
    return switch (d) {
        .v1 => stringify(a, .{ .reply = choice, .message = message }),
        .v2 => stringify(a, .{ .decision = choice, .message = message }),
    };
}

/// One question as `questionBody` needs it.
pub const Asked = struct {
    key: []const u8,
    kind: FieldKind,
    options: []const []const u8,
    values: []const []const u8,
};

/// The reply to a question request: `answers[i]` holds question i's
/// picked option labels or its free text. 1.x takes them as they are; 2.x
/// takes `{answer: {key: value}}` with each label mapped to its option
/// value and encoded by the field's kind.
pub fn questionBody(d: Dialect, a: std.mem.Allocator, asked: []const Asked, answers: []const []const []const u8) ![]u8 {
    if (d == .v1) return stringify(a, .{ .answers = answers });
    var obj: std.json.ObjectMap = .empty;
    for (asked, answers) |q, picked| {
        var values = std.json.Array.init(a);
        for (picked) |label| try values.append(.{ .string = valueOf(q, label) });
        const v: Value = switch (q.kind) {
            .multiselect => .{ .array = values },
            .boolean => .{ .bool = picked.len > 0 and std.mem.eql(u8, valueOf(q, picked[0]), "true") },
            .number, .integer => blk: {
                const s = if (picked.len > 0) std.mem.trim(u8, picked[0], " ") else "";
                const f = std.fmt.parseFloat(f64, s) catch return error.NoSuchOption;
                break :blk if (q.kind == .integer) .{ .integer = @intFromFloat(f) } else .{ .float = f };
            },
            .string, .external => .{ .string = if (picked.len > 0) valueOf(q, picked[0]) else "" },
        };
        try obj.put(a, q.key, v);
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "answer", .{ .object = obj });
    return std.json.Stringify.valueAlloc(a, Value{ .object = root }, .{});
}

/// The option value of `label` (free text is its own value).
fn valueOf(q: Asked, label: []const u8) []const u8 {
    for (q.options, 0..) |o, i| {
        if (std.mem.eql(u8, o, label) and i < q.values.len) return q.values[i];
    }
    return label;
}

/// Run command `name` with `arguments`; 1.x carries the model.
pub fn commandBody(d: Dialect, a: std.mem.Allocator, name: []const u8, arguments: []const u8, model: ?ModelChoice) ![]u8 {
    return switch (d) {
        .v1 => {
            var buf: [256]u8 = undefined;
            const spec: ?[]const u8 = if (model) |m| std.fmt.bufPrint(&buf, "{s}/{s}", .{ m.provider, m.model }) catch null else null;
            return stringify(a, .{
                .command = name,
                .arguments = arguments,
                .model = spec,
                .variant = if (model) |m| m.variant else null,
            });
        },
        .v2 => stringify(a, .{ .name = name, .text = arguments }),
    };
}

fn stringify(a: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false });
}

// ── JSON helpers ─────────────────────────────────────────────────

fn build(a: std.mem.Allocator, v: anytype) !Value {
    return parse(a, try stringify(a, v));
}

fn parse(a: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

fn get(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn boolean(v: Value, key: []const u8) ?bool {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

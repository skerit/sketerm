//! The `opencode_api` source: opencode's HTTP API and SSE event stream
//! mapped to the same outputs as the screen engine (records, state, the
//! pending interaction, errors and events in an `events.Queue`).
//!
//! `Source` is the pure half: it is fed the SSE event objects (live, or a
//! recording in `replay --opencode`) and knows nothing about sockets.
//! `Api` is the IO half: one keep-alive `http.Client` for requests and one
//! long-lived `http.EventStream`, reconnected and resynced when it drops.
//!
//! Subagents are CHILD sessions (`parentID`). Records come from the root
//! session only (a subagent's result reaches the root as its `task` tool
//! output), but the state and the pending interactions cover every
//! descendant: a child's unanswered permission hangs the root forever.
//! Everything is decided from the events' content, never from wall-clock
//! gaps, except the settle guard and the retry surfacing delay.

const std = @import("std");
const vocab = @import("vocab.zig");
const adapter = @import("adapter.zig");
const events = @import("events.zig");
const output = @import("output.zig");
const grammar = @import("grammar.zig");
const http = @import("http.zig");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");

pub const Record = output.Record;
pub const Interaction = output.Interaction;
const Value = std.json.Value;

/// `done` fires this long after the root went idle even when one of its
/// messages never reported completion.
pub const SETTLE_MS: i64 = 1500;

/// The event types this source reads; every other type is ignored.
const EventType = enum {
    @"server.connected",
    @"session.created",
    @"session.updated",
    @"session.deleted",
    @"session.status",
    @"session.idle",
    @"session.compacted",
    @"message.updated",
    @"message.part.updated",
    @"message.part.delta",
    @"permission.asked",
    @"permission.replied",
    @"question.asked",
    @"question.replied",
    @"question.rejected",
};

/// Part types that become records; every other type is ignored.
const PartType = enum { text, tool, subtask, compaction };

const SessionStatus = enum { idle, busy, retry };

/// opencode's permission replies. The option labels the assistant sees,
/// in API order, plus the words it may answer with.
pub const PermissionReply = enum {
    once,
    always,
    reject,

    pub fn label(self: PermissionReply) []const u8 {
        return switch (self) {
            .once => "Allow once",
            .always => "Allow always",
            .reject => "Reject",
        };
    }

    fn synonyms(self: PermissionReply) []const []const u8 {
        return switch (self) {
            .once => &.{ "once", "yes", "y", "allow", "ok" },
            .always => &.{"always"},
            .reject => &.{ "reject", "deny", "no", "n" },
        };
    }

    /// A reply from an option label, a 1-based index or a synonym.
    pub fn fromChoice(it: Interaction, choice: []const u8) ?PermissionReply {
        if (it.pick(choice)) |i| return std.enums.fromInt(PermissionReply, i);
        const want = std.mem.trim(u8, choice, " \t\r\n");
        for (std.enums.values(PermissionReply)) |r| {
            for (r.synonyms()) |s| {
                if (std.ascii.eqlIgnoreCase(s, want)) return r;
            }
        }
        return null;
    }
};

const permission_options = blk: {
    var opts: [std.enums.values(PermissionReply).len]output.Option = undefined;
    for (std.enums.values(PermissionReply), 0..) |r, i| opts[i] = .{ .label = r.label(), .selected = false };
    break :blk opts;
};

pub const Question = struct {
    text: []const u8,
    header: []const u8,
    options: []const []const u8,
    multiple: bool,
    /// A free-text answer is accepted.
    custom: bool,
};

/// A permission or question request of some session (root or not).
pub const Pending = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    session: []const u8,
    interaction: Interaction,
    /// The question request's questions (empty for a permission).
    questions: []const Question,
    announced: bool = false,

    fn destroy(self: *Pending, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

const Session = struct {
    parent: ?[]u8 = null,
    /// The parent relation is known (a created/updated event or a GET).
    known: bool = false,
    status: SessionStatus = .idle,
    retry_since_ms: ?i64 = null,
    retry_message: []u8 = &.{},
    /// A lookup for its parent was already attempted.
    resolving: bool = false,
};

const Role = enum { user, assistant };

const Message = struct {
    role: Role,
    session: []u8,
    completed: bool = false,
    /// Its error was handled (a notice or an error event).
    error_seen: bool = false,
    /// The turn (index of the root user message) it belongs to.
    turn: u32,
};

/// A streamed text part not finalized yet.
const LiveText = struct {
    message: []u8,
    text: std.ArrayList(u8) = .empty,
};

pub const Model = struct {
    provider: []const u8,
    model: []const u8,
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    loaded: *const adapter.Loaded,
    queue: events.Queue,

    /// The session the agent drives; adopted from the first parentless
    /// `session.created` when not given.
    root: ?[]u8 = null,
    sessions: std.StringHashMapUnmanaged(Session) = .empty,
    messages: std.StringHashMapUnmanaged(Message) = .empty,
    live: std.StringHashMapUnmanaged(LiveText) = .empty,

    records: std.ArrayList(Record) = .empty,
    /// The opencode part (or message) id each record came from.
    refs: std.ArrayList([]u8) = .empty,
    by_ref: std.StringHashMapUnmanaged(usize) = .empty,
    next_record_id: u64 = 1,
    /// Root user messages seen; the current turn is `turns - 1`.
    turns: u32 = 0,

    pending: std.ArrayList(*Pending) = .empty,

    connected: bool = false,
    ready: bool = false,
    state: vocab.State = .starting,
    done_armed: bool = false,
    idle_since_ms: ?i64 = null,
    retry_reported: bool = false,
    exited: bool = false,
    disconnected: bool = false,

    /// The model the latest root prompt ran with (as the server reports it).
    seen_model: ?[2][]u8 = null,
    seen_variant: ?[]u8 = null,
    /// The `now_ms` of the input being applied.
    clock_ms: i64 = 0,
    /// Replaying history (an adopted session's past): no turn is armed and
    /// no `message` event is pushed.
    quiet: bool = false,

    /// @param root the session to drive; null adopts the first parentless one.
    pub fn init(allocator: std.mem.Allocator, loaded: *const adapter.Loaded, limits: events.Limits, root: ?[]const u8) !Source {
        if (loaded.spec.source != .opencode_api) return error.NotAnApiAdapter;
        var self = Source{ .allocator = allocator, .loaded = loaded, .queue = events.Queue.init(allocator, limits) };
        if (root) |r| self.root = try allocator.dupe(u8, r);
        return self;
    }

    pub fn deinit(self: *Source) void {
        const a = self.allocator;
        if (self.root) |r| a.free(r);
        var sit = self.sessions.iterator();
        while (sit.next()) |e| {
            a.free(e.key_ptr.*);
            if (e.value_ptr.parent) |p| a.free(p);
            a.free(e.value_ptr.retry_message);
        }
        self.sessions.deinit(a);
        var mit = self.messages.iterator();
        while (mit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.session);
        }
        self.messages.deinit(a);
        var lit = self.live.iterator();
        while (lit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.message);
            e.value_ptr.text.deinit(a);
        }
        self.live.deinit(a);
        for (self.records.items) |r| r.deinit(a);
        self.records.deinit(a);
        for (self.refs.items) |r| a.free(r);
        self.refs.deinit(a);
        self.by_ref.deinit(a);
        for (self.pending.items) |p| p.destroy(a);
        self.pending.deinit(a);
        if (self.seen_model) |m| {
            a.free(m[0]);
            a.free(m[1]);
        }
        if (self.seen_variant) |v| a.free(v);
        self.queue.deinit();
    }

    // ── inputs ───────────────────────────────────────────────────

    /// Apply one SSE event object (`{"type": ..., "properties": ...}`).
    pub fn apply(self: *Source, ev: Value, now_ms: i64) !void {
        if (self.exited) return;
        self.clock_ms = now_ms;
        const type_name = str(ev, "type") orelse return;
        const props = get(ev, "properties") orelse Value{ .null = {} };
        const kind = std.meta.stringToEnum(EventType, type_name) orelse return;
        switch (kind) {
            .@"server.connected" => self.connected = true,
            .@"session.created", .@"session.updated" => try self.applySessionInfo(get(props, "info") orelse return),
            .@"session.deleted" => if (get(props, "info")) |info| {
                if (str(info, "id")) |id| (try self.session(id)).status = .idle;
            },
            .@"session.status" => try self.applyStatus(str(props, "sessionID") orelse return, get(props, "status") orelse return, now_ms),
            .@"session.idle" => try self.setStatus(str(props, "sessionID") orelse return, .idle, null, now_ms),
            .@"session.compacted" => if (self.isRoot(str(props, "sessionID") orelse return)) {
                try self.notice("compacted:", "conversation compacted");
            },
            .@"message.updated" => try self.applyMessage(get(props, "info") orelse return, now_ms),
            .@"message.part.updated" => try self.applyPart(get(props, "part") orelse return, now_ms),
            .@"message.part.delta" => try self.applyDelta(props),
            .@"permission.asked" => try self.addPermission(props),
            .@"question.asked" => try self.addQuestion(props),
            .@"permission.replied", .@"question.replied", .@"question.rejected" => self.removePending(str(props, "requestID") orelse return),
        }
        try self.evaluate(now_ms);
    }

    /// Time passed without events (settle guard, retry surfacing).
    pub fn tick(self: *Source, now_ms: i64) !void {
        if (self.exited) return;
        try self.evaluate(now_ms);
    }

    /// The server went away for good.
    pub fn noteExited(self: *Source, now_ms: i64, status: ?i32) !void {
        if (self.exited) return;
        if (status) |s| {
            if (s != 0) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "exited with status {d}", .{s}) catch "exited abnormally";
                _ = try self.queue.push(now_ms, .@"error", .crashed, text, "");
            }
        }
        _ = try self.queue.push(now_ms, .exited, null, "", "");
        self.exited = true;
        self.state = .exited;
    }

    /// The event stream dropped (the caller reconnects and resyncs).
    pub fn noteDisconnected(self: *Source, now_ms: i64, reason: []const u8) !void {
        if (self.disconnected or self.exited) return;
        _ = try self.queue.push(now_ms, .connection_lost, null, reason, "");
        self.disconnected = true;
        self.connected = false;
        self.state = .disconnected;
    }

    /// The event stream is back.
    pub fn noteReconnected(self: *Source, now_ms: i64) !void {
        self.disconnected = false;
        self.connected = true;
        try self.evaluate(now_ms);
    }

    /// Adopt `id` as the root session (a session the adapter created).
    pub fn setRoot(self: *Source, id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, id);
        if (self.root) |r| self.allocator.free(r);
        self.root = owned;
        const s = try self.session(id);
        s.known = true;
    }

    /// Record something the adapter did that the app leaves no trace of.
    pub fn addNotice(self: *Source, text: []const u8) !void {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "notice:{d}", .{self.next_record_id}) catch unreachable;
        _ = try self.upsert(key, .notice, text, null, true);
    }

    /// Replace the pending requests with the server's lists (a resync).
    /// @param perms the `GET /permission` array; @param questions `GET /question`.
    pub fn resyncPending(self: *Source, perms: Value, questions: Value, now_ms: i64) !void {
        self.clock_ms = now_ms;
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        defer keep.deinit(self.allocator);
        for ([_]Value{ perms, questions }) |list| {
            if (list != .array) continue;
            for (list.array.items) |req| {
                if (str(req, "id")) |id| try keep.put(self.allocator, id, {});
            }
        }
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            if (keep.contains(p.id)) {
                i += 1;
                continue;
            }
            p.destroy(self.allocator);
            _ = self.pending.orderedRemove(i);
        }
        if (perms == .array) {
            for (perms.array.items) |req| try self.addPermission(req);
        }
        if (questions == .array) {
            for (questions.array.items) |req| try self.addQuestion(req);
        }
        try self.evaluate(now_ms);
    }

    /// Replace session statuses with `GET /session/status` (absent = idle).
    pub fn resyncStatus(self: *Source, map: Value, now_ms: i64) !void {
        self.clock_ms = now_ms;
        // Collected first: `setStatus` may grow the map under an iterator.
        var unlisted: std.ArrayList([]const u8) = .empty;
        defer unlisted.deinit(self.allocator);
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            const listed = if (map == .object) map.object.contains(e.key_ptr.*) else false;
            if (!listed) try unlisted.append(self.allocator, e.key_ptr.*);
        }
        for (unlisted.items) |id| try self.setStatus(id, .idle, null, now_ms);
        if (map == .object) {
            var mit = map.object.iterator();
            while (mit.next()) |e| try self.applyStatus(e.key_ptr.*, e.value_ptr.*, now_ms);
        }
        try self.evaluate(now_ms);
    }

    /// Apply a `GET /session/{id}/message` array (`[{info, parts}]`).
    /// @param history the messages predate the agent (an adopted session):
    /// they arm no turn and announce no message.
    pub fn resyncMessages(self: *Source, list: Value, now_ms: i64, history: bool) !void {
        if (list != .array) return;
        self.clock_ms = now_ms;
        self.quiet = history;
        defer self.quiet = false;
        for (list.array.items) |m| {
            if (get(m, "info")) |info| try self.applyMessage(info, now_ms);
            if (get(m, "parts")) |parts| {
                if (parts != .array) continue;
                for (parts.array.items) |p| try self.applyPart(p, now_ms);
            }
        }
        try self.evaluate(now_ms);
    }

    /// Apply a `GET /session/{id}` object (learns an unknown session's parent).
    pub fn applySessionObject(self: *Source, info: Value, now_ms: i64) !void {
        try self.applySessionInfo(info);
        try self.evaluate(now_ms);
    }

    // ── read side ────────────────────────────────────────────────

    /// Records with an id above `since`, oldest first.
    pub fn recordsSince(self: *const Source, since: u64, out: *std.ArrayList(Record), alloc: std.mem.Allocator) !void {
        for (self.records.items) |r| {
            if (r.id > since) try out.append(alloc, r);
        }
        std.mem.sort(Record, out.items, {}, struct {
            fn lt(_: void, a: Record, b: Record) bool {
                return a.id < b.id;
            }
        }.lt);
    }

    /// The oldest unanswered request of the root or a descendant.
    pub fn pendingRequest(self: *const Source) ?*Pending {
        for (self.pending.items) |p| {
            if (self.visible(p.session)) return p;
        }
        return null;
    }

    pub fn interaction(self: *const Source) ?Interaction {
        const p = self.pendingRequest() orelse return null;
        return p.interaction;
    }

    /// Sessions whose parent is unknown (the IO half looks them up once).
    pub fn unresolvedSession(self: *Source) ?[]const u8 {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.known or e.value_ptr.resolving) continue;
            if (self.root != null and std.mem.eql(u8, e.key_ptr.*, self.root.?)) continue;
            e.value_ptr.resolving = true;
            return e.key_ptr.*;
        }
        return null;
    }

    /// The model the next prompt runs with when none is chosen: the latest
    /// root prompt's.
    pub fn seenModel(self: *const Source) ?Model {
        const m = self.seen_model orelse return null;
        return .{ .provider = m[0], .model = m[1] };
    }

    /// Milliseconds until a `tick` can change something, or null.
    pub fn tickDueIn(self: *const Source, now_ms: i64) ?i64 {
        var due: ?i64 = null;
        if (self.done_armed) {
            if (self.idle_since_ms) |since| due = @max(0, since + SETTLE_MS - now_ms);
        }
        if (self.root) |r| {
            if (self.sessions.get(r)) |s| {
                if (s.retry_since_ms) |since| {
                    if (!self.retry_reported) {
                        const d = @max(0, since + vocab.ErrorClass.retrying.surfaceAfterMs() - now_ms);
                        due = if (due) |x| @min(x, d) else d;
                    }
                }
            }
        }
        return due;
    }

    // ── sessions ─────────────────────────────────────────────────

    fn session(self: *Source, id: []const u8) !*Session {
        const gop = try self.sessions.getOrPut(self.allocator, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, id) catch |err| {
                self.sessions.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn applySessionInfo(self: *Source, info: Value) !void {
        const id = str(info, "id") orelse return;
        const parent = str(info, "parentID");
        if (self.root == null and parent == null) self.root = try self.allocator.dupe(u8, id);
        const s = try self.session(id);
        if (parent) |p| {
            if (s.parent == null) s.parent = try self.allocator.dupe(u8, p);
        }
        s.known = true;
        if (self.isRoot(id)) {
            // oc11 keeps a session-level model; stock only per message.
            if (get(info, "model")) |m| try self.noteModel(str(m, "providerID"), str(m, "id"), str(m, "variant"));
        }
    }

    fn applyStatus(self: *Source, id: []const u8, status: Value, now_ms: i64) !void {
        const name = str(status, "type") orelse return;
        const st = std.meta.stringToEnum(SessionStatus, name) orelse return;
        try self.setStatus(id, st, if (st == .retry) str(status, "message") orelse "" else null, now_ms);
    }

    fn setStatus(self: *Source, id: []const u8, st: SessionStatus, retry_message: ?[]const u8, now_ms: i64) !void {
        const s = try self.session(id);
        s.status = st;
        if (st == .retry) {
            if (s.retry_since_ms == null) s.retry_since_ms = now_ms;
            const msg = try self.allocator.dupe(u8, retry_message orelse "");
            self.allocator.free(s.retry_message);
            s.retry_message = msg;
        } else s.retry_since_ms = null;
        if (!self.isRoot(id)) return;
        if (st != .retry) self.retry_reported = false;
        if (st == .idle) {
            if (self.idle_since_ms == null) self.idle_since_ms = now_ms;
        } else self.idle_since_ms = null;
    }

    fn isRoot(self: *const Source, id: []const u8) bool {
        const r = self.root orelse return false;
        return std.mem.eql(u8, r, id);
    }

    /// The root itself or one of its descendants.
    fn visible(self: *const Source, id: []const u8) bool {
        var cur = id;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            if (self.isRoot(cur)) return true;
            const s = self.sessions.get(cur) orelse return false;
            cur = s.parent orelse return false;
        }
        return false;
    }

    fn descendantBusy(self: *const Source) bool {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            if (self.isRoot(e.key_ptr.*) or e.value_ptr.status == .idle) continue;
            if (self.visible(e.key_ptr.*)) return true;
        }
        return false;
    }

    // ── messages and parts ───────────────────────────────────────

    fn applyMessage(self: *Source, info: Value, now_ms: i64) !void {
        _ = now_ms;
        const id = str(info, "id") orelse return;
        const sid = str(info, "sessionID") orelse return;
        const role = std.meta.stringToEnum(Role, str(info, "role") orelse return) orelse return;
        const gop = try self.messages.getOrPut(self.allocator, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, id) catch |err| {
                self.messages.removeByPtr(gop.key_ptr);
                return err;
            };
            const session_copy = self.allocator.dupe(u8, sid) catch |err| {
                self.allocator.free(gop.key_ptr.*);
                self.messages.removeByPtr(gop.key_ptr);
                return err;
            };
            if (role == .user and self.isRoot(sid)) {
                self.turns += 1;
                if (!self.quiet) self.startTurn();
            }
            gop.value_ptr.* = .{ .role = role, .session = session_copy, .turn = self.turns -| 1 };
        }
        const m = gop.value_ptr;
        if (!self.isRoot(sid)) return;
        if (role == .user) {
            if (get(info, "model")) |model| try self.noteModel(str(model, "providerID"), str(model, "modelID"), str(info, "variant"));
            return;
        }
        const completed = if (get(info, "time")) |tm| get(tm, "completed") != null else false;
        if (completed and !m.completed) {
            m.completed = true;
            try self.finalizeLiveOf(id);
        }
        if (get(info, "error")) |err| {
            if (err != .null and !m.error_seen) {
                m.error_seen = true;
                try self.messageError(id, err);
            }
        }
    }

    /// A new root prompt starts a turn: `done` is armed again.
    fn startTurn(self: *Source) void {
        self.done_armed = true;
        self.idle_since_ms = null;
    }

    fn messageError(self: *Source, message_id: []const u8, err: Value) !void {
        const name = str(err, "name") orelse "UnknownError";
        const data = get(err, "data") orelse Value{ .null = {} };
        const text = str(data, "message") orelse "";
        var key_buf: [160]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "error:{s}", .{message_id}) catch "error:";
        if (std.mem.eql(u8, name, "MessageAbortedError")) {
            _ = try self.upsert(key, .notice, "interrupted", null, false);
            return;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.appendSlice(self.allocator, name);
        if (int(data, "statusCode")) |code| try line.print(self.allocator, " {d}", .{code});
        if (text.len > 0) try line.print(self.allocator, ": {s}", .{text});
        const hit = grammar.matchError(self.loaded.errors, line.items);
        const class: vocab.ErrorClass = if (hit) |h| h.class else .unknown;
        const detail = if (hit) |h| h.detail else "";
        _ = try self.queue.push(self.clockNow(), .@"error", class, line.items, detail);
        const note = try std.fmt.allocPrint(self.allocator, "error: {s}", .{line.items});
        defer self.allocator.free(note);
        _ = try self.upsert(key, .notice, note, null, false);
    }

    fn applyPart(self: *Source, part: Value, now_ms: i64) !void {
        _ = now_ms;
        const pid = str(part, "id") orelse return;
        const sid = str(part, "sessionID") orelse return;
        if (!self.isRoot(sid)) return;
        const mid = str(part, "messageID") orelse "";
        const ptype = std.meta.stringToEnum(PartType, str(part, "type") orelse return) orelse return;
        switch (ptype) {
            .text => {
                if (boolean(part, "synthetic") orelse false) return;
                if (boolean(part, "ignored") orelse false) return;
                const text = str(part, "text") orelse "";
                // A part of an unknown message: only assistant text is timed.
                const role: Role = if (self.messages.get(mid)) |m| m.role else if (get(part, "time") == null) .user else .assistant;
                if (role == .user) {
                    if (std.mem.trim(u8, text, " \n").len == 0) return;
                    _ = try self.upsert(pid, .user, text, null, false);
                    return;
                }
                const ended = if (get(part, "time")) |tm| get(tm, "end") != null else false;
                if (!ended) return self.liveSnapshot(pid, mid, text);
                self.dropLive(pid);
                try self.finalizeText(pid, text);
            },
            .tool => {
                const state = get(part, "state") orelse return;
                const status = std.meta.stringToEnum(vocab.ToolStatus, str(state, "status") orelse return) orelse return;
                // A pending call has no input yet: it is not a call to report.
                if (status == .pending) return;
                const name = str(part, "tool") orelse "tool";
                const input = if (get(state, "input")) |in| try compactJson(self.allocator, in) else try self.allocator.dupe(u8, "{}");
                defer self.allocator.free(input);
                const out = switch (status) {
                    .@"error" => str(state, "error") orelse "",
                    else => str(state, "output") orelse "",
                };
                const summary = try toolSummary(self.allocator, name, get(state, "input"));
                defer self.allocator.free(summary);
                _ = try self.upsert(pid, .tool, summary, .{ .name = name, .input = input, .status = status, .output = out }, false);
            },
            .subtask => {
                const cmd = str(part, "command") orelse str(part, "agent") orelse "subtask";
                const desc = str(part, "description") orelse "";
                const text = try std.fmt.allocPrint(self.allocator, "/{s} (subtask): {s}", .{ cmd, desc });
                defer self.allocator.free(text);
                _ = try self.upsert(pid, .notice, text, null, false);
            },
            .compaction => _ = try self.upsert(pid, .notice, "compaction", null, false),
        }
    }

    fn applyDelta(self: *Source, props: Value) !void {
        const sid = str(props, "sessionID") orelse return;
        if (!self.isRoot(sid)) return;
        if (!std.mem.eql(u8, str(props, "field") orelse "", "text")) return;
        const pid = str(props, "partID") orelse return;
        const mid = str(props, "messageID") orelse "";
        if (self.messages.get(mid)) |m| {
            if (m.role == .user) return;
        }
        if (self.by_ref.contains(pid)) return; // already final
        const lt = try self.liveEntry(pid, mid);
        try lt.text.appendSlice(self.allocator, str(props, "delta") orelse "");
    }

    fn liveEntry(self: *Source, pid: []const u8, mid: []const u8) !*LiveText {
        const gop = try self.live.getOrPut(self.allocator, pid);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, pid) catch |err| {
                self.live.removeByPtr(gop.key_ptr);
                return err;
            };
            const m = self.allocator.dupe(u8, mid) catch |err| {
                self.allocator.free(gop.key_ptr.*);
                self.live.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{ .message = m };
        }
        return gop.value_ptr;
    }

    /// An unfinished text part's full snapshot replaces what the deltas built.
    fn liveSnapshot(self: *Source, pid: []const u8, mid: []const u8, text: []const u8) !void {
        if (self.by_ref.contains(pid)) return;
        const lt = try self.liveEntry(pid, mid);
        if (text.len < lt.text.items.len) return; // deltas are ahead
        lt.text.clearRetainingCapacity();
        try lt.text.appendSlice(self.allocator, text);
    }

    fn dropLive(self: *Source, pid: []const u8) void {
        const kv = self.live.fetchRemove(pid) orelse return;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value.message);
        var text = kv.value.text;
        text.deinit(self.allocator);
    }

    /// A message completed: its text parts still streaming are final now.
    fn finalizeLiveOf(self: *Source, message_id: []const u8) !void {
        var done_parts: std.ArrayList([]const u8) = .empty;
        defer done_parts.deinit(self.allocator);
        var it = self.live.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.message, message_id)) try done_parts.append(self.allocator, e.key_ptr.*);
        }
        for (done_parts.items) |pid| {
            const lt = self.live.get(pid).?;
            const text = try self.allocator.dupe(u8, lt.text.items);
            defer self.allocator.free(text);
            const key = try self.allocator.dupe(u8, pid);
            defer self.allocator.free(key);
            self.dropLive(pid);
            try self.finalizeText(key, text);
        }
    }

    fn finalizeText(self: *Source, pid: []const u8, text: []const u8) !void {
        if (std.mem.trim(u8, text, " \n").len == 0) return;
        const rec = (try self.upsert(pid, .assistant, text, null, false)) orelse return;
        if (rec.announced) return;
        rec.announced = true;
        if (self.quiet) return;
        _ = try self.queue.push(self.clockNow(), .message, null, rec.text, "");
    }

    const ToolFields = struct {
        name: []const u8,
        input: []const u8,
        status: vocab.ToolStatus,
        output: []const u8,
    };

    /// Create or update the record for `ref`.
    /// @return the record when it was created or changed, null when unchanged.
    fn upsert(self: *Source, ref: []const u8, kind: vocab.RecordKind, text: []const u8, tool: ?ToolFields, synthetic: bool) !?*Record {
        const a = self.allocator;
        if (self.by_ref.get(ref)) |i| {
            const r = &self.records.items[i];
            if (sameContent(r.*, text, tool)) return null;
            const new_text = try a.dupe(u8, text);
            errdefer a.free(new_text);
            const new_tool = if (tool) |tf| try dupeTool(a, tf) else null;
            r.deinit(a);
            r.text = new_text;
            r.tool = new_tool;
            r.kind = kind;
            r.id = self.nextId();
            return r;
        }
        const owned_ref = try a.dupe(u8, ref);
        errdefer a.free(owned_ref);
        const owned_text = try a.dupe(u8, text);
        errdefer a.free(owned_text);
        const owned_tool = if (tool) |tf| try dupeTool(a, tf) else null;
        errdefer if (owned_tool) |tc| tc.deinit(a);
        try self.records.ensureUnusedCapacity(a, 1);
        try self.refs.ensureUnusedCapacity(a, 1);
        try self.by_ref.put(a, owned_ref, self.records.items.len);
        self.refs.appendAssumeCapacity(owned_ref);
        self.records.appendAssumeCapacity(.{
            .id = self.nextId(),
            .kind = kind,
            .text = owned_text,
            .turn = self.turns -| 1,
            .synthetic = synthetic,
            .tool = owned_tool,
        });
        return &self.records.items[self.records.items.len - 1];
    }

    fn nextId(self: *Source) u64 {
        const id = self.next_record_id;
        self.next_record_id += 1;
        return id;
    }

    fn notice(self: *Source, key_prefix: []const u8, text: []const u8) !void {
        var buf: [48]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}{d}", .{ key_prefix, self.next_record_id }) catch unreachable;
        _ = try self.upsert(key, .notice, text, null, false);
    }

    fn noteModel(self: *Source, provider: ?[]const u8, model: ?[]const u8, variant: ?[]const u8) !void {
        const p = provider orelse return;
        const m = model orelse return;
        const np = try self.allocator.dupe(u8, p);
        errdefer self.allocator.free(np);
        const nm = try self.allocator.dupe(u8, m);
        if (self.seen_model) |old| {
            self.allocator.free(old[0]);
            self.allocator.free(old[1]);
        }
        self.seen_model = .{ np, nm };
        if (self.seen_variant) |v| self.allocator.free(v);
        self.seen_variant = null;
        if (variant) |v| {
            if (!std.mem.eql(u8, v, "default")) self.seen_variant = try self.allocator.dupe(u8, v);
        }
    }

    // ── pending requests ─────────────────────────────────────────

    fn findPending(self: *const Source, id: []const u8) ?usize {
        for (self.pending.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) return i;
        }
        return null;
    }

    /// Forget request `id` (answered, or gone from the server).
    pub fn removePending(self: *Source, id: []const u8) void {
        const i = self.findPending(id) orelse return;
        self.pending.items[i].destroy(self.allocator);
        _ = self.pending.orderedRemove(i);
    }

    fn newPending(self: *Source, id: []const u8, sid: []const u8) !*Pending {
        const p = try self.allocator.create(Pending);
        p.arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer p.destroy(self.allocator);
        const a = p.arena.allocator();
        p.id = try a.dupe(u8, id);
        p.session = try a.dupe(u8, sid);
        p.questions = &.{};
        p.announced = false;
        return p;
    }

    fn addPermission(self: *Source, req: Value) !void {
        const id = str(req, "id") orelse return;
        const sid = str(req, "sessionID") orelse return;
        if (self.findPending(id) != null) return;
        _ = try self.session(sid);
        const p = try self.newPending(id, sid);
        errdefer p.destroy(self.allocator);
        const a = p.arena.allocator();
        const perm = str(req, "permission") orelse "permission";
        var patterns: std.ArrayList(u8) = .empty;
        const pats = get(req, "patterns") orelse Value{ .null = {} };
        if (pats == .array) {
            for (pats.array.items, 0..) |x, i| {
                if (x != .string) continue;
                if (i > 0) try patterns.appendSlice(a, ", ");
                try patterns.appendSlice(a, x.string);
            }
        }
        var detail: std.ArrayList(u8) = .empty;
        if (get(req, "always")) |al| {
            if (al == .array and al.array.items.len > 0) {
                try detail.appendSlice(a, "always would allow: ");
                for (al.array.items, 0..) |x, i| {
                    if (x != .string) continue;
                    if (i > 0) try detail.appendSlice(a, ", ");
                    try detail.appendSlice(a, x.string);
                }
            }
        }
        if (!self.isRoot(sid)) {
            if (detail.items.len > 0) try detail.append(a, '\n');
            try detail.print(a, "asked by subagent session {s}", .{sid});
        }
        p.interaction = .{
            .kind = .permission,
            .title = try std.fmt.allocPrint(a, "{s}: {s}", .{ perm, patterns.items }),
            .detail = detail.items,
            .hint = "",
            .options = &permission_options,
        };
        try self.pending.append(self.allocator, p);
    }

    fn addQuestion(self: *Source, req: Value) !void {
        const id = str(req, "id") orelse return;
        const sid = str(req, "sessionID") orelse return;
        if (self.findPending(id) != null) return;
        _ = try self.session(sid);
        const p = try self.newPending(id, sid);
        errdefer p.destroy(self.allocator);
        const a = p.arena.allocator();
        var qs: std.ArrayList(Question) = .empty;
        const list = get(req, "questions") orelse Value{ .null = {} };
        if (list == .array) {
            for (list.array.items) |q| {
                var labels: std.ArrayList([]const u8) = .empty;
                const opts = get(q, "options") orelse Value{ .null = {} };
                if (opts == .array) {
                    for (opts.array.items) |o| {
                        if (str(o, "label")) |l| try labels.append(a, try a.dupe(u8, l));
                    }
                }
                try qs.append(a, .{
                    .text = try a.dupe(u8, str(q, "question") orelse ""),
                    .header = try a.dupe(u8, str(q, "header") orelse ""),
                    .options = labels.items,
                    .multiple = boolean(q, "multiple") orelse false,
                    .custom = boolean(q, "custom") orelse true,
                });
            }
        }
        if (qs.items.len == 0) {
            p.destroy(self.allocator);
            return;
        }
        p.questions = qs.items;
        const first = qs.items[0];
        const opts = try a.alloc(output.Option, first.options.len);
        for (first.options, opts) |l, *o| o.* = .{ .label = l, .selected = false };
        var hint: []const u8 = "";
        if (qs.items.len > 1) {
            hint = try std.fmt.allocPrint(a, "{d} questions: answer each on its own line", .{qs.items.len});
        } else if (first.multiple) hint = "several options may be chosen, separated by commas";
        p.interaction = .{
            .kind = .question,
            .title = first.text,
            .detail = first.header,
            .hint = hint,
            .options = opts,
        };
        try self.pending.append(self.allocator, p);
    }

    // ── evaluation ───────────────────────────────────────────────

    fn clockNow(self: *const Source) i64 {
        return self.clock_ms;
    }

    fn evaluate(self: *Source, now_ms: i64) !void {
        self.clock_ms = now_ms;
        if (self.exited) return;
        self.ready = self.connected and self.root != null;
        for (self.pending.items) |p| {
            if (p.announced or !self.visible(p.session)) continue;
            p.announced = true;
            _ = try p.interaction.announce(&self.queue, now_ms);
        }
        if (self.disconnected) return;
        const root_session: ?Session = if (self.root) |r| self.sessions.get(r) else null;
        const root_status: SessionStatus = if (root_session) |s| s.status else .idle;

        var retry_persists = false;
        if (root_session) |s| {
            if (s.retry_since_ms) |since| {
                if (now_ms - since >= vocab.ErrorClass.retrying.surfaceAfterMs()) {
                    retry_persists = true;
                    if (!self.retry_reported) {
                        self.retry_reported = true;
                        _ = try self.queue.push(now_ms, .@"error", .retrying, if (s.retry_message.len > 0) s.retry_message else "retrying", "");
                    }
                }
            }
        }
        const children_busy = self.descendantBusy();
        self.state = if (!self.ready)
            .starting
        else if (self.pendingRequest() != null)
            .waiting_user
        else if (retry_persists)
            .retrying
        else if (root_status != .idle)
            (if (children_busy and self.taskRunning()) .waiting_subagent else .working)
        else if (children_busy)
            .waiting_subagent
        else
            .idle;

        if (self.state == .idle and self.done_armed and self.settled(now_ms)) {
            self.done_armed = false;
            _ = try self.queue.push(now_ms, .done, null, self.finalMessage(), "");
        }
    }

    /// A `task` tool call of the root is running.
    fn taskRunning(self: *const Source) bool {
        for (self.records.items) |r| {
            const tc = r.tool orelse continue;
            if (tc.status == .running and std.mem.eql(u8, tc.name, "task")) return true;
        }
        return false;
    }

    /// The root went idle after the turn's prompt, and the turn answered
    /// (every root assistant message of it completed, at least one) or the
    /// settle guard ran out. The prompt arrives before the server goes busy,
    /// so an idle root without an answer is not a finished turn.
    fn settled(self: *const Source, now_ms: i64) bool {
        const since = self.idle_since_ms orelse return false;
        if (now_ms - since >= SETTLE_MS) return true;
        var answered = false;
        var it = self.messages.iterator();
        while (it.next()) |e| {
            const m = e.value_ptr;
            if (m.role != .assistant or !self.isRoot(m.session) or m.turn + 1 != self.turns) continue;
            if (!m.completed) return false;
            answered = true;
        }
        return answered;
    }

    /// The latest assistant record of the current turn ("" when none).
    fn finalMessage(self: *const Source) []const u8 {
        const turn = self.turns -| 1;
        var best: ?Record = null;
        for (self.records.items) |r| {
            if (r.kind != .assistant or r.turn != turn) continue;
            best = r;
        }
        return if (best) |b| b.text else "";
    }
};

fn sameContent(r: Record, text: []const u8, tool: ?Source.ToolFields) bool {
    if (!std.mem.eql(u8, r.text, text)) return false;
    const a = r.tool orelse return tool == null;
    const b = tool orelse return false;
    return a.status == b.status and std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.input, b.input) and std.mem.eql(u8, a.output, b.output);
}

fn dupeTool(a: std.mem.Allocator, tf: Source.ToolFields) !output.ToolCall {
    const name = try a.dupe(u8, tf.name);
    errdefer a.free(name);
    const input = try a.dupe(u8, tf.input);
    errdefer a.free(input);
    const out = try a.dupe(u8, tf.output);
    return .{ .name = name, .input = input, .status = tf.status, .output = out };
}

/// Input keys that name what a call acts on, most telling first.
const summary_keys = [_][]const u8{ "command", "filePath", "path", "pattern", "query", "url", "description", "prompt" };
const SUMMARY_MAX = 200;

/// `<tool>: <what it acts on>`, one line.
fn toolSummary(a: std.mem.Allocator, name: []const u8, input: ?Value) ![]u8 {
    var what: []const u8 = "";
    var owned: ?[]u8 = null;
    defer if (owned) |o| a.free(o);
    if (input) |in| {
        for (summary_keys) |k| {
            if (str(in, k)) |v| {
                if (v.len > 0) {
                    what = v;
                    break;
                }
            }
        } else {
            owned = try compactJson(a, in);
            what = owned.?;
        }
    }
    const line_end = std.mem.indexOfScalar(u8, what, '\n') orelse what.len;
    const cut = @min(line_end, SUMMARY_MAX);
    const ellipsis = if (cut < what.len) "…" else "";
    return std.fmt.allocPrint(a, "{s}: {s}{s}", .{ name, what[0..cut], ellipsis });
}

fn compactJson(a: std.mem.Allocator, v: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
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

// ── the API side ─────────────────────────────────────────────────

/// Where the server listens and how to authenticate.
pub const Endpoint = struct {
    port: u16,
    /// Held in memory only: never argv, never logged.
    password: []const u8,
    user: []const u8 = "opencode",
};

/// Every synchronous request's deadline (loopback; `/provider` is the
/// slowest at a few MiB).
pub const REQUEST_TIMEOUT_MS: i64 = 10_000;
/// The readiness route (`probeHealth`).
pub const HEALTH_PATH = "/global/health";
/// One readiness probe's deadline: short, because a request the starting
/// server swallowed is never answered.
pub const HEALTH_PROBE_MS: i64 = 1000;
const RECONNECT_MIN_MS: i64 = 500;
const RECONNECT_MAX_MS: i64 = 10_000;

pub const ModelInfo = struct {
    provider: []const u8,
    id: []const u8,
    name: []const u8,
    /// The model's effort levels (`variant` names).
    variants: []const []const u8,
};

pub const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
    /// `command`, `mcp` or `skill`, as the server reports it.
    source: []const u8,
    /// It runs in a child session (a subagent).
    subtask: bool,
};

pub const ActionError = error{
    NoSession,
    NoPendingInteraction,
    NoSuchOption,
    UnknownModel,
    AmbiguousModel,
    UnknownEffort,
    NoCurrentModel,
    /// The server answered with a non-2xx status; `Api.problem` says why.
    Rejected,
    BadReply,
};

/// The models of the connected providers (`GET /provider`), cached.
const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    models: []const ModelInfo,

    fn find(self: *const Catalog, provider: []const u8, id: []const u8) ?*const ModelInfo {
        for (self.models) |*m| {
            if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }
};

pub const Api = struct {
    allocator: std.mem.Allocator,
    source: Source,
    client: http.Client,
    stream: http.EventStream,
    inbox: std.ArrayList(http.SseEvent) = .empty,
    reconnect_at_ms: ?i64 = null,
    backoff_ms: i64 = RECONNECT_MIN_MS,
    catalog: ?Catalog = null,
    chosen_model: ?[2][]u8 = null,
    chosen_variant: ?[]u8 = null,
    /// Tickets of `runCommand` requests in flight (the route answers when
    /// the command's turn ends).
    commands: std.ArrayList(u64) = .empty,
    problem_buf: [512]u8 = undefined,
    problem_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, loaded: *const adapter.Loaded, limits: events.Limits, endpoint: Endpoint) !Api {
        var source = try Source.init(allocator, loaded, limits, null);
        errdefer source.deinit();
        const client = try http.Client.init(allocator, .{ .port = endpoint.port, .user = endpoint.user, .password = endpoint.password });
        return .{ .allocator = allocator, .source = source, .client = client, .stream = http.EventStream.init(allocator) };
    }

    pub fn deinit(self: *Api) void {
        for (self.inbox.items) |e| e.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.stream.deinit();
        self.client.deinit();
        if (self.catalog) |*cat| cat.arena.deinit();
        self.clearChosenModel();
        if (self.chosen_variant) |v| self.allocator.free(v);
        self.commands.deinit(self.allocator);
        self.source.deinit();
    }

    /// Why the last action or request failed ("" when none did).
    pub fn problem(self: *const Api) []const u8 {
        return self.problem_buf[0..self.problem_len];
    }

    fn fail(self: *Api, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.problem_buf, fmt, args) catch self.problem_buf[0..];
        self.problem_len = s.len;
    }

    /// One readiness probe: `GET /global/health` with its own deadline.
    /// A starting opencode accepts connections seconds before it answers,
    /// and a request sent in that window is never answered at all; a
    /// probe that times out drops its connection, so the next one dials
    /// fresh. Call it until true before `connect`.
    /// @return true once the server answered 200; error.Unauthorized when
    /// it refuses the password (no point waiting).
    pub fn probeHealth(self: *Api, deadline_ms: i64) !bool {
        const r = self.client.call(.{ .method = .GET, .path = HEALTH_PATH }, deadline_ms) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.fail("GET " ++ HEALTH_PATH ++ ": {s}", .{@errorName(err)});
            return false;
        };
        defer r.deinit(self.allocator);
        if (r.status == 200) return true;
        self.fail("GET " ++ HEALTH_PATH ++ ": {d} {s}", .{ r.status, r.body[0..@min(r.body.len, 200)] });
        if (r.status == 401) return error.Unauthorized;
        return false;
    }

    /// Open the event stream first (nothing is missed), then drive
    /// `session` or a new one, then read the server's current state.
    /// @param session an existing session to adopt; its past is history.
    pub fn connect(self: *Api, session: ?[]const u8, now_ms: i64) !void {
        self.problem_len = 0;
        self.stream.open(&self.client, "/event", now_ms + REQUEST_TIMEOUT_MS) catch |err| {
            self.fail("GET /event: {s}", .{@errorName(err)});
            return err;
        };
        if (session) |id| {
            try self.source.setRoot(id);
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/session/{s}/message", .{id}) catch return error.NoSession;
            var msgs = try self.getJson(path);
            defer msgs.deinit();
            try self.source.resyncMessages(msgs.value, now_ms, true);
        } else {
            var created = try self.requestJson(.{ .method = .POST, .path = "/session", .body = "{}" });
            defer created.deinit();
            const id = str(created.value, "id") orelse {
                self.fail("POST /session: no id in the reply", .{});
                return error.BadReply;
            };
            try self.source.setRoot(id);
        }
        try self.resync(now_ms);
        try self.source.noteReconnected(now_ms);
    }

    /// The session the agent drives.
    pub fn sessionId(self: *const Api) ?[]const u8 {
        return self.source.root;
    }

    /// The fds to watch for input (the event stream, async requests).
    pub fn pollFds(self: *const Api, out: []c.struct_pollfd) usize {
        var n: usize = 0;
        if (self.stream.fd >= 0 and out.len > 0) {
            out[0] = .{ .fd = self.stream.fd, .events = c.POLLIN, .revents = 0 };
            n = 1;
        }
        return n + self.client.pollFds(out[n..]);
    }

    /// Milliseconds until `service` must run even without fd activity.
    pub fn serviceDueIn(self: *const Api, now_ms: i64) ?i64 {
        var due = self.source.tickDueIn(now_ms);
        if (self.reconnect_at_ms) |at| {
            const d = @max(0, at - now_ms);
            due = if (due) |x| @min(x, d) else d;
        }
        return due;
    }

    /// Read the event stream, finish async requests, reconnect a dropped
    /// stream (then resync), and let time-based rules fire. Never blocks
    /// on the stream; lookups of unknown sessions are short requests.
    pub fn service(self: *Api, now_ms: i64) !void {
        if (self.source.exited) return;
        if (self.stream.isOpen()) {
            const alive = self.stream.read(&self.inbox) catch false;
            try self.drainInbox(now_ms);
            if (!alive) {
                try self.source.noteDisconnected(now_ms, "event stream closed");
                self.backoff_ms = RECONNECT_MIN_MS;
                self.reconnect_at_ms = now_ms + self.backoff_ms;
            }
        } else if (self.reconnect_at_ms) |at| {
            if (now_ms >= at) self.reconnect(now_ms);
        }
        try self.client.service(now_ms);
        while (self.client.takeCompletion()) |done| try self.finished(done, now_ms);
        while (self.source.unresolvedSession()) |id| {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/session/{s}", .{id}) catch continue;
            var info = self.getJson(path) catch continue;
            defer info.deinit();
            try self.source.applySessionObject(info.value, now_ms);
        }
        try self.source.tick(now_ms);
    }

    fn drainInbox(self: *Api, now_ms: i64) !void {
        defer {
            for (self.inbox.items) |e| e.deinit(self.allocator);
            self.inbox.clearRetainingCapacity();
        }
        for (self.inbox.items) |e| {
            var parsed = std.json.parseFromSlice(Value, self.allocator, e.data, .{}) catch continue;
            defer parsed.deinit();
            try self.source.apply(parsed.value, now_ms);
        }
    }

    fn reconnect(self: *Api, now_ms: i64) void {
        self.stream.open(&self.client, "/event", now_ms + REQUEST_TIMEOUT_MS) catch {
            self.backoff_ms = @min(self.backoff_ms * 2, RECONNECT_MAX_MS);
            self.reconnect_at_ms = now_ms + self.backoff_ms;
            return;
        };
        self.reconnect_at_ms = null;
        self.backoff_ms = RECONNECT_MIN_MS;
        self.resync(now_ms) catch {};
        if (self.source.root) |root| {
            var path_buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "/session/{s}/message", .{root})) |path| {
                if (self.getJson(path)) |msgs_const| {
                    var msgs = msgs_const;
                    defer msgs.deinit();
                    self.source.resyncMessages(msgs.value, now_ms, false) catch {};
                } else |_| {}
            } else |_| {}
        }
        self.source.noteReconnected(now_ms) catch {};
    }

    /// Statuses and pending requests as the server has them now.
    fn resync(self: *Api, now_ms: i64) !void {
        var status = try self.getJson("/session/status");
        defer status.deinit();
        try self.source.resyncStatus(status.value, now_ms);
        var perms = try self.getJson("/permission");
        defer perms.deinit();
        var questions = try self.getJson("/question");
        defer questions.deinit();
        try self.source.resyncPending(perms.value, questions.value, now_ms);
    }

    fn finished(self: *Api, done: http.Completion, now_ms: i64) !void {
        const i = std.mem.indexOfScalar(u64, self.commands.items, done.ticket) orelse {
            if (done.result == .response) done.result.response.deinit(self.allocator);
            return;
        };
        _ = self.commands.orderedRemove(i);
        switch (done.result) {
            .response => |r| {
                defer r.deinit(self.allocator);
                if (r.ok()) return;
                self.fail("command: {d} {s}", .{ r.status, r.body[0..@min(r.body.len, 300)] });
            },
            .failed => |err| self.fail("command: {s}", .{@errorName(err)}),
        }
        _ = try self.source.queue.push(now_ms, .@"error", .api, self.problem(), "");
    }

    /// The server's process ended.
    pub fn noteExited(self: *Api, now_ms: i64, status: ?i32) !void {
        self.stream.close();
        self.reconnect_at_ms = null;
        try self.source.noteExited(now_ms, status);
    }

    // ── actions ──────────────────────────────────────────────────

    /// Send a prompt; the reply streams in as events.
    /// @param agent_name an opencode agent (`build`, `plan`), or the session's.
    pub fn submit(self: *Api, text: []const u8, agent_name: ?[]const u8) !void {
        const root = self.source.root orelse return error.NoSession;
        const TextPart = struct { type: []const u8 = "text", text: []const u8 };
        const ModelRef = struct { providerID: []const u8, modelID: []const u8 };
        const model: ?ModelRef = if (self.chosenModel()) |m| .{ .providerID = m.provider, .modelID = m.model } else null;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .parts = [1]TextPart{.{ .text = text }},
            .model = model,
            .variant = self.chosen_variant,
            .agent = agent_name,
        }, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(body);
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/session/{s}/prompt_async", .{root}) catch return error.NoSession;
        const r = try self.request(.{ .method = .POST, .path = path, .body = body });
        r.deinit(self.allocator);
    }

    /// Answer the pending interaction by option label, 1-based index or (for
    /// a permission) a yes/no word. A question with several questions takes
    /// one answer per line; a multi-select one takes comma-separated labels.
    pub fn answer(self: *Api, choice: []const u8) !void {
        const p = self.source.pendingRequest() orelse return error.NoPendingInteraction;
        var path_buf: [256]u8 = undefined;
        switch (p.interaction.kind) {
            .permission => {
                const reply = PermissionReply.fromChoice(p.interaction, choice) orelse return error.NoSuchOption;
                const path = std.fmt.bufPrint(&path_buf, "/permission/{s}/reply", .{p.id}) catch return error.NoSuchOption;
                const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .reply = @tagName(reply) }, .{});
                defer self.allocator.free(body);
                const r = try self.request(.{ .method = .POST, .path = path, .body = body });
                r.deinit(self.allocator);
            },
            .question => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const answers = try questionAnswers(arena.allocator(), p.questions, choice);
                const path = std.fmt.bufPrint(&path_buf, "/question/{s}/reply", .{p.id}) catch return error.NoSuchOption;
                const body = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .answers = answers }, .{});
                const r = try self.request(.{ .method = .POST, .path = path, .body = body });
                r.deinit(self.allocator);
            },
            .choice => return error.NoSuchOption,
        }
        // Gone now; the replied event that follows is a no-op.
        const id = try self.allocator.dupe(u8, p.id);
        defer self.allocator.free(id);
        self.source.removePending(id);
    }

    /// Abort the running turn (subagents included).
    pub fn interrupt(self: *Api) !void {
        const root = self.source.root orelse return error.NoSession;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/session/{s}/abort", .{root}) catch return error.NoSession;
        const r = try self.request(.{ .method = .POST, .path = path });
        r.deinit(self.allocator);
    }

    /// Use `spec` (`provider/model`, or a model id or name unique among the
    /// connected providers) for the prompts this agent sends. Session
    /// scoped: nothing in the user's configuration changes.
    pub fn setModel(self: *Api, spec: []const u8) !void {
        const m = try self.resolveModel(spec);
        const provider = try self.allocator.dupe(u8, m.provider);
        errdefer self.allocator.free(provider);
        const id = try self.allocator.dupe(u8, m.id);
        self.clearChosenModel();
        self.chosen_model = .{ provider, id };
        if (self.chosen_variant) |v| {
            if (!hasVariant(m, v)) {
                self.allocator.free(v);
                self.chosen_variant = null;
            }
        }
    }

    /// Use effort `level` (a variant of the current model; `default`
    /// clears it) for the prompts this agent sends.
    pub fn setEffort(self: *Api, level: []const u8) !void {
        const cur = self.currentModel() orelse {
            self.fail("no current model: set a model first", .{});
            return error.NoCurrentModel;
        };
        const m = try self.catalogModel(cur.provider, cur.model);
        if (std.ascii.eqlIgnoreCase(level, "default")) {
            if (self.chosen_variant) |v| self.allocator.free(v);
            self.chosen_variant = null;
            return;
        }
        if (!hasVariant(m, level)) {
            self.fail("{s}/{s} has no effort level \"{s}\"", .{ m.provider, m.id, level });
            return error.UnknownEffort;
        }
        // The level belongs to this model: pin it.
        if (self.chosen_model == null) {
            const provider = try self.allocator.dupe(u8, m.provider);
            errdefer self.allocator.free(provider);
            const id = try self.allocator.dupe(u8, m.id);
            self.chosen_model = .{ provider, id };
        }
        const v = try self.allocator.dupe(u8, level);
        if (self.chosen_variant) |old| self.allocator.free(old);
        self.chosen_variant = v;
    }

    /// The model the next prompt runs with, when known.
    pub fn currentModel(self: *const Api) ?Model {
        return self.chosenModel() orelse self.source.seenModel();
    }

    /// The effort level the next prompt runs with, when known.
    pub fn currentEffort(self: *const Api) ?[]const u8 {
        return self.chosen_variant orelse self.source.seen_variant;
    }

    fn chosenModel(self: *const Api) ?Model {
        const m = self.chosen_model orelse return null;
        return .{ .provider = m[0], .model = m[1] };
    }

    fn clearChosenModel(self: *Api) void {
        if (self.chosen_model) |m| {
            self.allocator.free(m[0]);
            self.allocator.free(m[1]);
        }
        self.chosen_model = null;
    }

    /// The connected providers' models with their effort levels. Borrowed:
    /// valid until the catalog is reloaded (a model lookup that misses).
    pub fn listModels(self: *Api) ![]const ModelInfo {
        const cat = try self.loadCatalog(false);
        return cat.models;
    }

    /// The server's commands (`GET /command`), allocated from `arena`.
    pub fn listCommands(self: *Api, arena: std.mem.Allocator) ![]CommandInfo {
        var parsed = try self.getJson("/command");
        defer parsed.deinit();
        var out: std.ArrayList(CommandInfo) = .empty;
        if (parsed.value == .array) {
            for (parsed.value.array.items) |cmd| {
                const name = str(cmd, "name") orelse continue;
                try out.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .description = try arena.dupe(u8, str(cmd, "description") orelse ""),
                    .source = try arena.dupe(u8, str(cmd, "source") orelse "command"),
                    .subtask = boolean(cmd, "subtask") orelse false,
                });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Run command `name` with `arguments` in the session. The route
    /// answers only when the command's turn ends, so it runs in the
    /// background: its outcome streams in as events, and a refusal
    /// becomes an `error` event.
    pub fn runCommand(self: *Api, name: []const u8, arguments: []const u8) !void {
        const root = self.source.root orelse return error.NoSession;
        var model_buf: [256]u8 = undefined;
        const model: ?[]const u8 = if (self.chosenModel()) |m|
            std.fmt.bufPrint(&model_buf, "{s}/{s}", .{ m.provider, m.model }) catch null
        else
            null;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .command = name,
            .arguments = arguments,
            .model = model,
            .variant = self.chosen_variant,
        }, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(body);
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/session/{s}/command", .{root}) catch return error.NoSession;
        try self.commands.ensureUnusedCapacity(self.allocator, 1);
        const ticket = self.client.start(.{ .method = .POST, .path = path, .body = body }, null) catch |err| {
            self.fail("POST {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        self.commands.appendAssumeCapacity(ticket);
    }

    // ── requests ─────────────────────────────────────────────────

    /// A 2xx response, or `error.Rejected` with the status and body in
    /// `problem`.
    fn request(self: *Api, req: http.Request) !http.Response {
        const r = self.client.call(req, clock.nowMs() + REQUEST_TIMEOUT_MS) catch |err| {
            self.fail("{s} {s}: {s}", .{ @tagName(req.method), req.path, @errorName(err) });
            return err;
        };
        if (r.ok()) return r;
        defer r.deinit(self.allocator);
        self.fail("{s} {s}: {d} {s}", .{ @tagName(req.method), req.path, r.status, r.body[0..@min(r.body.len, 300)] });
        return error.Rejected;
    }

    fn requestJson(self: *Api, req: http.Request) !std.json.Parsed(Value) {
        const r = try self.request(req);
        defer r.deinit(self.allocator);
        return std.json.parseFromSlice(Value, self.allocator, r.body, .{}) catch {
            self.fail("{s} {s}: the reply is not JSON", .{ @tagName(req.method), req.path });
            return error.BadReply;
        };
    }

    fn getJson(self: *Api, path: []const u8) !std.json.Parsed(Value) {
        return self.requestJson(.{ .method = .GET, .path = path });
    }

    fn loadCatalog(self: *Api, refresh: bool) !*const Catalog {
        if (self.catalog) |*cat| {
            if (!refresh) return cat;
        }
        var parsed = try self.getJson("/provider");
        defer parsed.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var models: std.ArrayList(ModelInfo) = .empty;
        const connected = get(parsed.value, "connected") orelse Value{ .null = {} };
        const all = get(parsed.value, "all") orelse Value{ .null = {} };
        if (all == .array and connected == .array) {
            for (all.array.items) |prov| {
                const pid = str(prov, "id") orelse continue;
                if (!containsString(connected, pid)) continue;
                const ms = get(prov, "models") orelse continue;
                if (ms != .object) continue;
                var it = ms.object.iterator();
                while (it.next()) |e| {
                    var variants: std.ArrayList([]const u8) = .empty;
                    if (get(e.value_ptr.*, "variants")) |vs| {
                        if (vs == .object) {
                            for (vs.object.keys()) |k| try variants.append(a, try a.dupe(u8, k));
                        }
                    }
                    try models.append(a, .{
                        .provider = try a.dupe(u8, pid),
                        .id = try a.dupe(u8, e.key_ptr.*),
                        .name = try a.dupe(u8, str(e.value_ptr.*, "name") orelse e.key_ptr.*),
                        .variants = variants.items,
                    });
                }
            }
        }
        if (self.catalog) |*old| old.arena.deinit();
        self.catalog = .{ .arena = arena, .models = models.items };
        return &self.catalog.?;
    }

    fn resolveModel(self: *Api, spec: []const u8) !*const ModelInfo {
        var refreshed = false;
        while (true) : (refreshed = true) {
            const cat = try self.loadCatalog(refreshed);
            if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
                if (cat.find(spec[0..slash], spec[slash + 1 ..])) |m| return m;
            } else {
                var found: ?*const ModelInfo = null;
                var many = false;
                for (cat.models) |*m| {
                    if (!std.mem.eql(u8, m.id, spec) and !std.ascii.eqlIgnoreCase(m.name, spec)) continue;
                    if (found != null) many = true;
                    found = m;
                }
                if (many) {
                    self.fail("\"{s}\" names several models; use provider/model", .{spec});
                    return error.AmbiguousModel;
                }
                if (found) |m| return m;
            }
            if (refreshed) break;
        }
        self.fail("no connected provider has a model \"{s}\"", .{spec});
        return error.UnknownModel;
    }

    fn catalogModel(self: *Api, provider: []const u8, id: []const u8) !*const ModelInfo {
        if ((try self.loadCatalog(false)).find(provider, id)) |m| return m;
        if ((try self.loadCatalog(true)).find(provider, id)) |m| return m;
        self.fail("no connected provider has a model \"{s}/{s}\"", .{ provider, id });
        return error.UnknownModel;
    }
};

fn hasVariant(m: *const ModelInfo, level: []const u8) bool {
    for (m.variants) |v| {
        if (std.mem.eql(u8, v, level)) return true;
    }
    return false;
}

fn containsString(list: Value, s: []const u8) bool {
    for (list.array.items) |x| {
        if (x == .string and std.mem.eql(u8, x.string, s)) return true;
    }
    return false;
}

/// The reply body's `answers` for a question request: one line of `choice`
/// per question; each line is an option label or index, a comma-separated
/// list of them for a multi-select question, or free text where allowed.
fn questionAnswers(arena: std.mem.Allocator, questions: []const Question, choice: []const u8) ![]const []const []const u8 {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, choice, "\n"), '\n');
    const out = try arena.alloc([]const []const u8, questions.len);
    for (questions, out) |q, *slot| {
        const line = std.mem.trim(u8, lines.next() orelse return error.NoSuchOption, " \t\r");
        const opts = try arena.alloc(output.Option, q.options.len);
        for (q.options, opts) |l, *o| o.* = .{ .label = l, .selected = false };
        const it = Interaction{ .kind = .question, .title = q.text, .detail = q.header, .hint = "", .options = opts };
        var picked: std.ArrayList([]const u8) = .empty;
        if (it.pick(line)) |i| {
            try picked.append(arena, q.options[i]);
        } else if (q.multiple and std.mem.indexOfScalar(u8, line, ',') != null) {
            var parts = std.mem.splitScalar(u8, line, ',');
            while (parts.next()) |part| {
                const i = it.pick(part) orelse return error.NoSuchOption;
                try picked.append(arena, q.options[i]);
            }
        } else if (q.custom and line.len > 0) {
            try picked.append(arena, line);
        } else return error.NoSuchOption;
        slot.* = picked.items;
    }
    return out;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const testserver = @import("testserver.zig");

/// The shipped opencode adapter plus a Source fed hand-written events.
const Rig = struct {
    set: adapter.Set,
    src: Source,

    fn init(self: *Rig) !void {
        self.set = adapter.Set.init(t.allocator);
        errdefer self.set.deinit();
        try self.set.loadShipped();
        self.src = try Source.init(t.allocator, self.set.get("opencode").?, .{}, null);
    }

    fn deinit(self: *Rig) void {
        self.src.deinit();
        self.set.deinit();
    }

    fn feed(self: *Rig, now: i64, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(Value, t.allocator, json, .{});
        defer parsed.deinit();
        try self.src.apply(parsed.value, now);
    }

    fn count(self: *const Rig, kind: vocab.EventKind) usize {
        return countKind(&self.src.queue, kind);
    }

    fn last(self: *const Rig, kind: vocab.EventKind) ?events.Event {
        var i = self.src.queue.events.items.len;
        while (i > 0) {
            i -= 1;
            if (self.src.queue.events.items[i].kind == kind) return self.src.queue.events.items[i];
        }
        return null;
    }
};

fn countKind(q: *const events.Queue, kind: vocab.EventKind) usize {
    var n: usize = 0;
    for (q.events.items) |ev| {
        if (ev.kind == kind) n += 1;
    }
    return n;
}

fn connectRoot(rig: *Rig) !void {
    try rig.feed(0, "{\"type\":\"server.connected\",\"properties\":{}}");
    try rig.feed(0, "{\"type\":\"session.created\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"ses_root\",\"title\":\"x\"}}}");
}

/// A user prompt of the root session: its message and text part.
fn feedPrompt(rig: *Rig, now: i64, n: u32, body: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"message.updated","properties":{{"sessionID":"ses_root","info":{{"id":"msg_u{d}","role":"user","sessionID":"ses_root","time":{{"created":1}},"model":{{"providerID":"openai","modelID":"gpt-x"}}}}}}}}
    , .{n}));
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"message.part.updated","properties":{{"sessionID":"ses_root","part":{{"type":"text","text":"{s}","messageID":"msg_u{d}","sessionID":"ses_root","id":"prt_u{d}"}}}}}}
    , .{ body, n, n }));
}

fn feedStatus(rig: *Rig, now: i64, session: []const u8, kind: []const u8) !void {
    var buf: [256]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"session.status","properties":{{"sessionID":"{s}","status":{{"type":"{s}"}}}}}}
    , .{ session, kind }));
}

fn feedAssistant(rig: *Rig, now: i64, id: []const u8, completed: bool) !void {
    var buf: [512]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"message.updated","properties":{{"sessionID":"ses_root","info":{{"id":"{s}","role":"assistant","sessionID":"ses_root","time":{{"created":2{s}}}}}}}}}
    , .{ id, if (completed) ",\"completed\":3" else "" }));
}

fn feedText(rig: *Rig, now: i64, msg: []const u8, part: []const u8, body: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"message.part.updated","properties":{{"sessionID":"ses_root","part":{{"type":"text","text":"{s}","time":{{"start":1,"end":2}},"messageID":"{s}","sessionID":"ses_root","id":"{s}"}}}}}}
    , .{ body, msg, part }));
}

fn feedTool(rig: *Rig, now: i64, session: []const u8, part: []const u8, name: []const u8, st: []const u8, input: []const u8, out: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"message.part.updated","properties":{{"sessionID":"{s}","part":{{"type":"tool","tool":"{s}","callID":"c1","state":{{"status":"{s}","input":{s},"output":"{s}","error":"{s}"}},"id":"{s}","sessionID":"{s}","messageID":"msg_x"}}}}}}
    , .{ session, name, st, input, out, out, part, session }));
}

fn feedPermission(rig: *Rig, now: i64, id: []const u8, session: []const u8, command: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"permission.asked","properties":{{"id":"{s}","sessionID":"{s}","permission":"bash","patterns":["{s}"],"metadata":{{"command":"{s}"}},"always":["rm *"],"tool":{{"messageID":"m","callID":"c"}}}}}}
    , .{ id, session, command, command }));
}

fn feedReplied(rig: *Rig, now: i64, id: []const u8, session: []const u8) !void {
    var buf: [512]u8 = undefined;
    try rig.feed(now, try std.fmt.bufPrint(&buf,
        \\{{"type":"permission.replied","properties":{{"sessionID":"{s}","requestID":"{s}","reply":"once"}}}}
    , .{ session, id }));
}

test "a normal turn: no early done, streamed text, a tool record updated in place, one done" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.feed(0, "{\"type\":\"server.connected\",\"properties\":{}}");
    try t.expectEqual(vocab.State.starting, rig.src.state);
    try rig.feed(1, "{\"type\":\"session.created\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"ses_root\",\"title\":\"x\"}}}");
    try t.expectEqual(vocab.State.idle, rig.src.state);
    try feedPrompt(&rig, 10, 1, "read a.zig");
    // The prompt lands before the server goes busy: not a finished turn.
    try rig.src.tick(5000);
    try t.expectEqual(@as(usize, 0), rig.count(.done));
    try feedStatus(&rig, 5010, "ses_root", "busy");
    try t.expectEqual(vocab.State.working, rig.src.state);
    try feedAssistant(&rig, 5020, "msg_a1", false);
    try feedTool(&rig, 5030, "ses_root", "prt_t1", "read", "pending", "{}", "");
    try t.expectEqual(@as(usize, 1), rig.src.records.items.len);
    try feedTool(&rig, 5040, "ses_root", "prt_t1", "read", "running", "{\"filePath\":\"a.zig\"}", "");
    const running_id = rig.src.records.items[1].id;
    try feedTool(&rig, 5050, "ses_root", "prt_t1", "read", "completed", "{\"filePath\":\"a.zig\"}", "1: const x");
    try t.expectEqual(@as(usize, 2), rig.src.records.items.len);
    const tr = rig.src.records.items[1];
    try t.expect(tr.id > running_id);
    try t.expectEqual(vocab.ToolStatus.completed, tr.tool.?.status);
    try t.expectEqualStrings("read: a.zig", tr.text);
    try t.expectEqualStrings("{\"filePath\":\"a.zig\"}", tr.tool.?.input);
    try t.expectEqualStrings("1: const x", tr.tool.?.output);
    try feedAssistant(&rig, 5060, "msg_a1", true);
    try feedAssistant(&rig, 5070, "msg_a2", false);
    try rig.feed(5080, "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"part\":{\"type\":\"text\",\"text\":\"\",\"time\":{\"start\":1},\"messageID\":\"msg_a2\",\"sessionID\":\"ses_root\",\"id\":\"prt_a2\"}}}");
    try rig.feed(5090, "{\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"ses_root\",\"messageID\":\"msg_a2\",\"partID\":\"prt_a2\",\"field\":\"text\",\"delta\":\"It is \"}}");
    try t.expectEqual(@as(usize, 2), rig.src.records.items.len);
    try feedText(&rig, 5100, "msg_a2", "prt_a2", "It is a constant.");
    try feedAssistant(&rig, 5110, "msg_a2", true);
    try t.expectEqual(@as(usize, 0), rig.count(.done));
    try feedStatus(&rig, 5120, "ses_root", "idle");
    try t.expectEqual(vocab.State.idle, rig.src.state);
    try t.expectEqual(@as(usize, 1), rig.count(.done));
    try t.expectEqualStrings("It is a constant.", rig.last(.done).?.text);
    try t.expectEqual(@as(usize, 1), rig.count(.message));
    // The idle repeats (session.idle after session.status): still one done.
    try rig.feed(5130, "{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_root\"}}");
    try rig.src.tick(9000);
    try t.expectEqual(@as(usize, 1), rig.count(.done));
    const kinds = [_]vocab.RecordKind{ .user, .tool, .assistant };
    for (rig.src.records.items, kinds) |r, k| try t.expectEqual(k, r.kind);
    try t.expectEqualStrings("openai", rig.src.seenModel().?.provider);
}

test "a text part cut off by its message completing keeps what the deltas built" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try feedPrompt(&rig, 1, 1, "go");
    try feedStatus(&rig, 2, "ses_root", "busy");
    try feedAssistant(&rig, 3, "msg_a1", false);
    try rig.feed(4, "{\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"ses_root\",\"messageID\":\"msg_a1\",\"partID\":\"prt_a1\",\"field\":\"text\",\"delta\":\"partial answer\"}}");
    try feedAssistant(&rig, 5, "msg_a1", true);
    try t.expectEqualStrings("partial answer", rig.src.records.items[1].text);
}

test "a permission is needs_input with once/always/reject options, answered by label or word" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try feedPrompt(&rig, 10, 1, "delete notes");
    try feedStatus(&rig, 11, "ses_root", "busy");
    try feedAssistant(&rig, 12, "msg_a1", false);
    try feedTool(&rig, 13, "ses_root", "prt_t1", "bash", "running", "{\"command\":\"rm notes.md\"}", "");
    try feedPermission(&rig, 14, "per_1", "ses_root", "rm notes.md");
    try t.expectEqual(vocab.State.waiting_user, rig.src.state);
    const ev = rig.last(.needs_input).?;
    try t.expectEqualStrings("permission: bash: rm notes.md", ev.text);
    try t.expectEqualStrings("1. Allow once\n2. Allow always\n3. Reject", ev.detail);
    const it = rig.src.interaction().?;
    try t.expectEqualStrings("always would allow: rm *", it.detail);
    try t.expectEqual(PermissionReply.once, PermissionReply.fromChoice(it, "allow once").?);
    try t.expectEqual(PermissionReply.once, PermissionReply.fromChoice(it, "yes").?);
    try t.expectEqual(PermissionReply.always, PermissionReply.fromChoice(it, "2").?);
    try t.expectEqual(PermissionReply.always, PermissionReply.fromChoice(it, "Always").?);
    try t.expectEqual(PermissionReply.reject, PermissionReply.fromChoice(it, "deny").?);
    try t.expectEqual(PermissionReply.reject, PermissionReply.fromChoice(it, "no").?);
    try t.expect(PermissionReply.fromChoice(it, "perhaps") == null);
    try feedReplied(&rig, 20, "per_1", "ses_root");
    try t.expectEqual(vocab.State.working, rig.src.state);
    try t.expectEqual(@as(usize, 1), rig.count(.needs_input));
}

test "a subagent: waiting_subagent while its task runs, its permission is waiting_user, then done" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try feedPrompt(&rig, 10, 1, "use a subagent");
    try feedStatus(&rig, 11, "ses_root", "busy");
    try feedAssistant(&rig, 12, "msg_a1", false);
    try feedTool(&rig, 13, "ses_root", "prt_task", "task", "running", "{\"description\":\"find it\",\"subagent_type\":\"explore\"}", "");
    try rig.feed(14, "{\"type\":\"session.created\",\"properties\":{\"sessionID\":\"ses_kid\",\"info\":{\"id\":\"ses_kid\",\"parentID\":\"ses_root\",\"title\":\"find it\"}}}");
    try feedStatus(&rig, 15, "ses_kid", "busy");
    try t.expectEqual(vocab.State.waiting_subagent, rig.src.state);
    // The child's own transcript is not the root's.
    try feedTool(&rig, 17, "ses_kid", "prt_k", "bash", "running", "{\"command\":\"git diff\"}", "");
    try t.expectEqual(@as(usize, 2), rig.src.records.items.len);
    try feedPermission(&rig, 18, "per_kid", "ses_kid", "git diff");
    try t.expectEqual(vocab.State.waiting_user, rig.src.state);
    try t.expect(std.mem.indexOf(u8, rig.src.interaction().?.detail, "asked by subagent session ses_kid") != null);
    try t.expectEqual(@as(usize, 1), rig.count(.needs_input));
    try feedReplied(&rig, 19, "per_kid", "ses_kid");
    try t.expectEqual(vocab.State.waiting_subagent, rig.src.state);
    try feedStatus(&rig, 20, "ses_kid", "idle");
    try feedTool(&rig, 21, "ses_root", "prt_task", "task", "completed", "{\"description\":\"find it\",\"subagent_type\":\"explore\"}", "screen.zig");
    try t.expectEqual(vocab.State.working, rig.src.state);
    try feedAssistant(&rig, 22, "msg_a1", true);
    try feedAssistant(&rig, 23, "msg_a2", false);
    try feedText(&rig, 24, "msg_a2", "prt_a2", "It is in screen.zig.");
    try feedAssistant(&rig, 25, "msg_a2", true);
    try feedStatus(&rig, 26, "ses_root", "idle");
    try t.expectEqual(@as(usize, 1), rig.count(.done));
    try t.expectEqualStrings("It is in screen.zig.", rig.last(.done).?.text);
}

test "a pending request of a session with unknown lineage shows once the lineage is known" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try feedPermission(&rig, 1, "per_x", "ses_late", "ls");
    try t.expect(rig.src.interaction() == null);
    try t.expectEqualStrings("ses_late", rig.src.unresolvedSession().?);
    try t.expect(rig.src.unresolvedSession() == null);
    var parsed = try std.json.parseFromSlice(Value, t.allocator, "{\"id\":\"ses_late\",\"parentID\":\"ses_root\"}", .{});
    defer parsed.deinit();
    try rig.src.applySessionObject(parsed.value, 2);
    try t.expectEqual(vocab.State.waiting_user, rig.src.state);
    try t.expectEqual(@as(usize, 1), rig.count(.needs_input));
}

test "retry surfaces only once it persists; errors follow the adapter's rules; an abort is a notice" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try feedPrompt(&rig, 100_000, 1, "hi");
    try rig.feed(100_000, "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_root\",\"status\":{\"type\":\"retry\",\"attempt\":1,\"message\":\"Provider is overloaded\",\"next\":1}}}");
    try t.expectEqual(vocab.State.working, rig.src.state);
    try rig.src.tick(105_000);
    try t.expectEqual(vocab.State.working, rig.src.state);
    try t.expectEqual(@as(i64, 5000), rig.src.tickDueIn(105_000).?);
    try rig.src.tick(110_500);
    try t.expectEqual(vocab.State.retrying, rig.src.state);
    const retry = rig.last(.@"error").?;
    try t.expectEqual(vocab.ErrorClass.retrying, retry.class.?);
    try t.expectEqualStrings("Provider is overloaded", retry.text);
    try feedStatus(&rig, 111_000, "ses_root", "busy");
    try t.expectEqual(vocab.State.working, rig.src.state);

    try rig.feed(111_100, "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1,\"completed\":2},\"error\":{\"name\":\"APIError\",\"data\":{\"message\":\"Rate limit exceeded\",\"statusCode\":429,\"isRetryable\":true}}}}}");
    const limit = rig.last(.@"error").?;
    try t.expectEqual(vocab.ErrorClass.limit, limit.class.?);
    try t.expectEqualStrings("APIError 429: Rate limit exceeded", limit.text);
    try feedStatus(&rig, 111_200, "ses_root", "idle");
    try t.expectEqual(@as(usize, 1), rig.count(.done));
    try t.expectEqualStrings("", rig.last(.done).?.text);

    try feedPrompt(&rig, 120_000, 2, "count to 5000");
    try feedStatus(&rig, 120_001, "ses_root", "busy");
    try feedAssistant(&rig, 120_002, "msg_a2", false);
    try feedStatus(&rig, 120_003, "ses_root", "idle");
    // Aborted: the idle comes before the message's completion.
    try t.expectEqual(@as(usize, 1), rig.count(.done));
    try rig.feed(120_004, "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a2\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1,\"completed\":2},\"error\":{\"name\":\"MessageAbortedError\",\"data\":{\"message\":\"Aborted\"}}}}}");
    try t.expectEqual(@as(usize, 2), rig.count(.done));
    try t.expectEqual(@as(usize, 2), rig.count(.@"error"));
    const recs = rig.src.records.items;
    try t.expectEqualStrings("interrupted", recs[recs.len - 1].text);
    try t.expectEqual(vocab.RecordKind.notice, recs[recs.len - 1].kind);

    try feedPrompt(&rig, 130_000, 3, "again");
    try feedStatus(&rig, 130_001, "ses_root", "busy");
    try rig.feed(130_002, "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a3\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1,\"completed\":2},\"error\":{\"name\":\"ProviderAuthError\",\"data\":{\"providerID\":\"openai\",\"message\":\"Invalid API key\"}}}}}");
    try t.expectEqual(vocab.ErrorClass.auth, rig.last(.@"error").?.class.?);
    try rig.feed(130_003, "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a4\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1,\"completed\":2},\"error\":{\"name\":\"UnknownError\",\"data\":{\"message\":\"boom\"}}}}}");
    try t.expectEqual(vocab.ErrorClass.unknown, rig.last(.@"error").?.class.?);
}

test "a question request: options, custom answers and several questions" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try connectRoot(&rig);
    try rig.feed(1, "{\"type\":\"question.asked\",\"properties\":{\"id\":\"que_1\",\"sessionID\":\"ses_root\",\"questions\":[{\"question\":\"Which file?\",\"header\":\"File\",\"options\":[{\"label\":\"a.zig\",\"description\":\"\"},{\"label\":\"b.zig\",\"description\":\"\"}]},{\"question\":\"Which checks?\",\"header\":\"Checks\",\"multiple\":true,\"custom\":false,\"options\":[{\"label\":\"lint\",\"description\":\"\"},{\"label\":\"test\",\"description\":\"\"}]}]}}");
    try t.expectEqual(vocab.State.waiting_user, rig.src.state);
    const p = rig.src.pendingRequest().?;
    try t.expectEqual(vocab.InteractionKind.question, p.interaction.kind);
    try t.expectEqualStrings("Which file?", p.interaction.title);
    try t.expectEqualStrings("b.zig", p.interaction.options[1].label);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ans = try questionAnswers(arena.allocator(), p.questions, "2\nlint, test");
    try t.expectEqualStrings("b.zig", ans[0][0]);
    try t.expectEqual(@as(usize, 2), ans[1].len);
    try t.expectEqualStrings("test", ans[1][1]);
    const custom = try questionAnswers(arena.allocator(), p.questions, "c.zig\ntest");
    try t.expectEqualStrings("c.zig", custom[0][0]);
    try t.expectError(error.NoSuchOption, questionAnswers(arena.allocator(), p.questions, "a.zig\nbuild"));
    try t.expectError(error.NoSuchOption, questionAnswers(arena.allocator(), p.questions, "a.zig"));
    try rig.feed(2, "{\"type\":\"question.rejected\",\"properties\":{\"sessionID\":\"ses_root\",\"requestID\":\"que_1\"}}");
    try t.expect(rig.src.interaction() == null);
}

test "adopted history arms no turn and announces nothing" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.src.setRoot("ses_root");
    try rig.src.noteReconnected(0);
    const history =
        \\[{"info":{"id":"msg_u1","role":"user","sessionID":"ses_root"},"parts":[{"type":"text","text":"old question","id":"prt_u1","sessionID":"ses_root","messageID":"msg_u1"}]},
        \\ {"info":{"id":"msg_a1","role":"assistant","sessionID":"ses_root","time":{"created":1,"completed":2}},"parts":[{"type":"text","text":"old answer","time":{"start":1,"end":2},"id":"prt_a1","sessionID":"ses_root","messageID":"msg_a1"}]}]
    ;
    var parsed = try std.json.parseFromSlice(Value, t.allocator, history, .{});
    defer parsed.deinit();
    try rig.src.resyncMessages(parsed.value, 1, true);
    var st = try std.json.parseFromSlice(Value, t.allocator, "{}", .{});
    defer st.deinit();
    try rig.src.resyncStatus(st.value, 2);
    try rig.src.tick(10_000);
    try t.expectEqual(@as(usize, 2), rig.src.records.items.len);
    try t.expectEqual(@as(usize, 0), rig.src.queue.events.items.len);
    try t.expectEqual(vocab.State.idle, rig.src.state);
}

/// Service `api` until `cond` holds or three seconds pass.
fn pumpUntil(api: *Api, comptime cond: fn (*Api) bool) !void {
    const deadline = clock.nowMs() + 3000;
    while (clock.nowMs() < deadline) {
        var pfds: [8]c.struct_pollfd = undefined;
        const n = api.pollFds(&pfds);
        _ = c.poll(&pfds, @intCast(n), 20);
        try api.service(clock.nowMs());
        if (cond(api)) return;
    }
    return error.TestTimeout;
}

fn countRequests(srv: *testserver.Server, prefix: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < srv.requestCount()) : (i += 1) {
        if (std.mem.startsWith(u8, srv.request(i), prefix)) n += 1;
    }
    return n;
}

const provider_json =
    \\{"all":[{"id":"openai","name":"OpenAI","models":{"gpt-x":{"name":"GPT X","variants":{"low":{},"high":{}}},"gpt-y":{"name":"GPT Y"}}},
    \\ {"id":"other","name":"Other","models":{"gpt-x":{"name":"GPT X"}}}],"default":{},"connected":["openai"]}
;

test "api: connect, submit with a chosen model and effort, answer, interrupt, commands, reconnect" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("POST /session", .{ .body = "{\"id\":\"ses_root\",\"title\":\"agent\"}" });
    srv.route("GET /session/status", .{ .body = "{}" });
    srv.route("GET /permission", .{ .body = "[]" });
    srv.route("GET /question", .{ .body = "[]" });
    srv.route("GET /session/ses_root/message", .{ .body = "[]" });
    srv.route("GET /provider", .{ .body = provider_json, .chunked = true });
    srv.route("POST /session/ses_root/prompt_async", .{ .status = 204, .events = &.{
        "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_u1\",\"role\":\"user\",\"sessionID\":\"ses_root\"}}}",
        "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"part\":{\"type\":\"text\",\"text\":\"hello\",\"messageID\":\"msg_u1\",\"sessionID\":\"ses_root\",\"id\":\"prt_u1\"}}}",
        "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_root\",\"status\":{\"type\":\"busy\"}}}",
        "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1}}}}",
        "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"part\":{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"running\",\"input\":{\"command\":\"rm x\"}},\"messageID\":\"msg_a1\",\"sessionID\":\"ses_root\",\"id\":\"prt_t1\"}}}",
        "{\"type\":\"permission.asked\",\"properties\":{\"id\":\"per_1\",\"sessionID\":\"ses_root\",\"permission\":\"bash\",\"patterns\":[\"rm x\"],\"metadata\":{},\"always\":[\"rm *\"]}}",
    } });
    srv.route("POST /permission/per_1/reply", .{ .body = "true", .events = &.{
        "{\"type\":\"permission.replied\",\"properties\":{\"sessionID\":\"ses_root\",\"requestID\":\"per_1\",\"reply\":\"once\"}}",
        "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"part\":{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"rm x\"},\"output\":\"\"},\"messageID\":\"msg_a1\",\"sessionID\":\"ses_root\",\"id\":\"prt_t1\"}}}",
        "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"part\":{\"type\":\"text\",\"text\":\"Removed x.\",\"time\":{\"start\":1,\"end\":2},\"messageID\":\"msg_a1\",\"sessionID\":\"ses_root\",\"id\":\"prt_a1\"}}}",
        "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_root\",\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"sessionID\":\"ses_root\",\"time\":{\"created\":1,\"completed\":2}}}}",
        "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_root\",\"status\":{\"type\":\"idle\"}}}",
    } });
    srv.route("POST /session/ses_root/abort", .{ .body = "true" });
    srv.route("GET /command", .{ .body = "[{\"name\":\"review\",\"description\":\"review changes\",\"source\":\"command\",\"template\":\"x\",\"subtask\":true,\"hints\":[]}]" });
    srv.route("POST /session/ses_root/command", .{ .status = 400, .body = "{\"_tag\":\"InvalidRequestError\",\"message\":\"no such command\"}", .delay_ms = 100 });

    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    var api = try Api.init(t.allocator, set.get("opencode").?, .{}, .{ .port = srv.port(), .password = "secret" });
    defer api.deinit();
    try api.connect(null, clock.nowMs());
    try t.expectEqualStrings("ses_root", api.sessionId().?);
    try t.expect(std.mem.startsWith(u8, srv.request(0), "GET /event HTTP/1.1"));
    try t.expect(std.mem.indexOf(u8, srv.request(0), "Authorization: Basic b3BlbmNvZGU6c2VjcmV0\r\n") != null);
    try t.expectEqual(vocab.State.idle, api.source.state);

    // Model and effort: validated against the connected providers only.
    try api.setModel("gpt-x");
    try t.expectEqualStrings("openai", api.currentModel().?.provider);
    try api.setEffort("high");
    try t.expectError(error.UnknownEffort, api.setEffort("max"));
    try t.expect(std.mem.indexOf(u8, api.problem(), "no effort level \"max\"") != null);
    try t.expectError(error.UnknownModel, api.setModel("other/gpt-x"));
    try t.expectError(error.UnknownModel, api.setModel("nope"));
    try t.expectEqualStrings("high", api.currentEffort().?);
    const models = try api.listModels();
    try t.expectEqual(@as(usize, 2), models.len);
    try t.expectEqual(@as(usize, 2), models[0].variants.len);

    try api.submit("hello", null);
    const sent = srv.lastRequest("POST /session/ses_root/prompt_async").?;
    try t.expect(std.mem.endsWith(u8, sent, "{\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}],\"model\":{\"providerID\":\"openai\",\"modelID\":\"gpt-x\"},\"variant\":\"high\"}"));
    try pumpUntil(&api, struct {
        fn f(a: *Api) bool {
            return countKind(&a.source.queue, .needs_input) == 1;
        }
    }.f);
    try t.expectEqual(vocab.State.waiting_user, api.source.state);
    try t.expectError(error.NoSuchOption, api.answer("maybe"));
    try api.answer("yes");
    try t.expect(std.mem.endsWith(u8, srv.lastRequest("POST /permission/per_1/reply").?, "{\"reply\":\"once\"}"));
    try t.expect(api.source.interaction() == null);
    try pumpUntil(&api, struct {
        fn f(a: *Api) bool {
            return countKind(&a.source.queue, .done) == 1;
        }
    }.f);
    var done_text: []const u8 = "";
    for (api.source.queue.events.items) |ev| {
        if (ev.kind == .done) done_text = ev.text;
    }
    try t.expectEqualStrings("Removed x.", done_text);
    try t.expectError(error.NoPendingInteraction, api.answer("yes"));

    try api.interrupt();
    try t.expect(srv.lastRequest("POST /session/ses_root/abort") != null);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cmds = try api.listCommands(arena.allocator());
    try t.expectEqual(@as(usize, 1), cmds.len);
    try t.expect(cmds[0].subtask);
    // The command route answers late; its refusal becomes an error event.
    try api.runCommand("reveiw", "");
    try t.expect(std.mem.endsWith(u8, srv.waitRequest("POST /session/ses_root/command", clock.nowMs() + 2000).?, "{\"command\":\"reveiw\",\"arguments\":\"\",\"model\":\"openai/gpt-x\",\"variant\":\"high\"}"));
    try pumpUntil(&api, struct {
        fn f(a: *Api) bool {
            return countKind(&a.source.queue, .@"error") == 1;
        }
    }.f);
    try t.expect(std.mem.indexOf(u8, api.problem(), "no such command") != null);

    // The stream drops: connection_lost, then a reconnect and a resync.
    const status_gets = countRequests(&srv, "GET /session/status");
    srv.endStreams();
    try pumpUntil(&api, struct {
        fn f(a: *Api) bool {
            return a.source.state == .disconnected;
        }
    }.f);
    try t.expectEqual(@as(usize, 1), countKind(&api.source.queue, .connection_lost));
    srv.resumeStreams();
    try pumpUntil(&api, struct {
        fn f(a: *Api) bool {
            return a.source.state == .idle;
        }
    }.f);
    try t.expect(countRequests(&srv, "GET /session/status") > status_gets);
    try t.expect(srv.lastRequest("GET /session/ses_root/message") != null);
    try t.expectEqual(@as(usize, 3), api.source.records.items.len);
}

test "api: a refused session create is Rejected with the status in problem()" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("POST /session", .{ .status = 401, .body = "{\"_tag\":\"UnauthorizedError\",\"message\":\"no\"}" });
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    var api = try Api.init(t.allocator, set.get("opencode").?, .{}, .{ .port = srv.port(), .password = "pw" });
    defer api.deinit();
    try t.expectError(error.Rejected, api.connect(null, clock.nowMs()));
    try t.expect(std.mem.indexOf(u8, api.problem(), "POST /session: 401") != null);
}

test "api: a starting server that swallows requests is waited out by short fresh health probes" {
    // opencode listens ~2 s after launch but answers only ~4.5 s in, and a
    // request sent in between is never answered: one long request (the
    // event stream's 10 s) hangs and fails; short probes get through.
    var srv: testserver.Server = .{};
    srv.deaf_until_ms = clock.nowMs() + 1200;
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("GET " ++ HEALTH_PATH, .{ .body = "{\"healthy\":true}" });
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    var api = try Api.init(t.allocator, set.get("opencode").?, .{}, .{ .port = srv.port(), .password = "pw" });
    defer api.deinit();

    // The first probe lands in the deaf window: it times out, not hangs.
    const t0 = clock.nowMs();
    try t.expect(!try api.probeHealth(t0 + 300));
    try t.expect(clock.nowMs() - t0 < 1000);
    try t.expect(std.mem.indexOf(u8, api.problem(), "Timeout") != null);
    var probes: u32 = 1;
    while (!try api.probeHealth(clock.nowMs() + 300)) {
        probes += 1;
        if (clock.nowMs() - t0 > 5000) return error.TestServerNeverAnswered;
    }
    try t.expect(probes >= 2);
    try t.expect(clock.nowMs() - t0 >= 1100);
    // Every probe after a swallowed one dialed fresh: the server saw as
    // many connections as probes (the answered one keeps its keep-alive).
    try t.expect(srv.connections() >= probes);

    // A wrong password is final, not something to wait out.
    var bad: testserver.Server = .{};
    bad.auth = "Basic b3BlbmNvZGU6cmlnaHQ=";
    try bad.start(t.allocator);
    defer bad.deinit();
    var api2 = try Api.init(t.allocator, set.get("opencode").?, .{}, .{ .port = bad.port(), .password = "wrong" });
    defer api2.deinit();
    try t.expectError(error.Unauthorized, api2.probeHealth(clock.nowMs() + 1000));
}

//! The transport-agnostic half of the LSP client: framing, JSON-RPC
//! bookkeeping, capability negotiation, document sync and
//! cancellation. It never touches a file descriptor — bytes come in
//! through `feed` and go out into `out`, which whoever owns the pipe
//! drains. That is what lets the whole protocol be unit-tested without
//! GTK, a process, or a real server (see src/lsp/session_test.zig).
//!
//! ## Staleness discipline
//!
//! Every request records the document `revision` it was built against.
//! A response whose recorded revision no longer matches the document is
//! the caller's to drop — `Request.revision` is handed back with the
//! response for exactly that check, mirroring what syntax.zig does with
//! its parse results. `seq` additionally supersedes: a newer request of
//! the same kind for the same tab makes the older one uninteresting
//! even at the same revision (the user typed another character), and
//! `cancel` sends `$/cancelRequest` so the server can stop working.
//!
//! ## Server -> client requests
//!
//! Must be answered or a server blocks forever. Anything we do not
//! implement is answered with a MethodNotFound error, and the two
//! progress-creation requests every server sends are answered `null`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("rpc.zig");
const pos = @import("position.zig");
const semantic = @import("semantic.zig");

pub const Encoding = pos.Encoding;

pub const State = enum {
    /// Constructed; `initialize` not sent yet.
    idle,
    /// `initialize` in flight.
    initializing,
    /// `initialized` sent; requests may flow.
    ready,
    /// `shutdown` in flight.
    stopping,
    /// The server is gone (exited, crashed, or framing was lost).
    dead,
};

pub const SyncKind = enum(u8) { none = 0, full = 1, incremental = 2 };

/// Requests sketerm issues. The tag travels with the response so the
/// caller does not have to keep its own id table.
pub const Kind = enum {
    initialize,
    shutdown,
    completion,
    completion_resolve,
    hover,
    definition,
    declaration,
    type_definition,
    references,
    document_symbol,
    workspace_symbol,
    rename,
    formatting,
    range_formatting,
    signature_help,
    code_action,
    code_action_resolve,
    execute_command,
    inlay_hint,
    semantic_tokens_full,
    semantic_tokens_delta,
};

pub const Request = struct {
    id: i64,
    kind: Kind,
    /// Editor tab the answer belongs to (0 = not tab-scoped).
    tab_id: u64 = 0,
    /// Document revision the request was built against.
    revision: u64 = 0,
    /// Monotonic per-kind sequence; a higher one supersedes.
    seq: u64 = 0,
    /// Free slot for caller state (the completion prefix start offset,
    /// the rename's target offset, …).
    aux: u64 = 0,
    cancelled: bool = false,
};

/// What the server said it can do. Everything defaults to "no", so a
/// server that answers `initialize` with `{}` simply offers nothing and
/// every feature degrades silently.
pub const Caps = struct {
    encoding: Encoding = .utf16,
    sync: SyncKind = .none,
    open_close: bool = false,
    save_notify: bool = false,
    save_include_text: bool = false,
    completion: bool = false,
    completion_resolve: bool = false,
    hover: bool = false,
    definition: bool = false,
    declaration: bool = false,
    type_definition: bool = false,
    references: bool = false,
    document_symbol: bool = false,
    workspace_symbol: bool = false,
    rename: bool = false,
    formatting: bool = false,
    range_formatting: bool = false,
    signature_help: bool = false,
    code_action: bool = false,
    code_action_resolve: bool = false,
    inlay_hint: bool = false,
    /// `semanticTokensProvider.full` — the whole-document request.
    semantic_tokens: bool = false,
    /// …and whether it also answers `semanticTokens/full/delta`.
    semantic_tokens_delta: bool = false,
    /// Characters that should pop the completion list open. Owned.
    completion_triggers: []u8 = &.{},
    /// Characters that open signature help, and the (usually smaller)
    /// set that updates an already-open one. Owned.
    signature_triggers: []u8 = &.{},
    signature_retriggers: []u8 = &.{},
    /// `tokenTypes` from the semantic-tokens legend. Owned.
    token_types: semantic.Legend = .{},

    pub fn deinit(self: *Caps, alloc: Allocator) void {
        for ([_]*[]u8{
            &self.completion_triggers,
            &self.signature_triggers,
            &self.signature_retriggers,
        }) |slot| {
            if (slot.len > 0) alloc.free(slot.*);
            slot.* = &.{};
        }
        self.token_types.deinit(alloc);
    }

    pub fn isTrigger(self: *const Caps, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.completion_triggers, ch) != null;
    }

    pub fn isSignatureTrigger(self: *const Caps, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.signature_triggers, ch) != null;
    }

    pub fn isSignatureRetrigger(self: *const Caps, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.signature_retriggers, ch) != null;
    }
};

/// One `textDocument/didChange` content change, in LSP coordinates.
/// `text` is borrowed for the duration of the call.
pub const ContentChange = struct {
    range: ?pos.Range = null,
    text: []const u8,
};

pub const Handler = struct {
    ctx: *anyopaque,
    /// A response to one of OUR requests. `req` carries the staleness
    /// metadata; `env.result` / `env.err_*` the payload.
    on_response: *const fn (ctx: *anyopaque, req: Request, env: rpc.Envelope) void,
    /// A server notification (publishDiagnostics, logMessage, …).
    on_notification: *const fn (ctx: *anyopaque, method: []const u8, params: std.json.Value) void,
    /// State transitions, including the move to `.dead`.
    on_state: *const fn (ctx: *anyopaque, state: State) void,
    /// `workspace/applyEdit`: the server asks US to write a
    /// `WorkspaceEdit`. This is how a code action that carries a
    /// `command` (rather than an inline edit) actually changes
    /// anything, so it cannot be answered generically here. @return
    /// what goes into the reply's `applied` field.
    on_apply_edit: *const fn (ctx: *anyopaque, params: std.json.Value) bool,
};

pub const Session = struct {
    alloc: Allocator,
    handler: Handler,
    reader: rpc.Reader = .{},
    /// Framed bytes waiting to go to the server's stdin.
    out: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(Request) = .empty,
    caps: Caps = .{},
    state: State = .idle,
    next_id: i64 = 1,
    next_seq: u64 = 1,
    /// Bumped per didChange, per document — LSP versions are per-URI.
    /// The editor opens one document per tab, so the tab's own counter
    /// is the version and lives on the caller's side.
    last_error: [240]u8 = undefined,
    last_error_len: usize = 0,

    pub fn init(alloc: Allocator, handler: Handler) Session {
        return .{ .alloc = alloc, .handler = handler };
    }

    pub fn deinit(self: *Session) void {
        self.reader.deinit(self.alloc);
        self.out.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        self.caps.deinit(self.alloc);
    }

    pub fn errText(self: *const Session) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    /// Record a diagnostic message, TRUNCATING rather than failing.
    /// Formatting straight into `last_error` would, on overflow, leave
    /// a partially-written buffer and a length of 5 ("error"), i.e. a
    /// misleading five-character prefix of the real message — which is
    /// exactly how a server's "initialize failed: <long reason>" once
    /// read as "initi".
    fn setErr(self: *Session, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        var n: usize = 0;
        if (std.fmt.bufPrint(&tmp, fmt, args)) |s| {
            n = s.len;
        } else |_| {
            n = tmp.len;
        }
        n = @min(n, self.last_error.len);
        @memcpy(self.last_error[0..n], tmp[0..n]);
        self.last_error_len = n;
    }

    fn setState(self: *Session, s: State) void {
        if (self.state == s) return;
        self.state = s;
        self.handler.on_state(self.handler.ctx, s);
    }

    /// The server's stdin is gone / the process exited.
    pub fn markDead(self: *Session) void {
        self.pending.clearRetainingCapacity();
        self.setState(.dead);
    }

    // ---- inbound ------------------------------------------------------

    /// Feed bytes read from the server's stdout. Framing errors kill
    /// the session (there is no way to resynchronise a lost stream).
    pub fn feed(self: *Session, bytes: []const u8) void {
        if (self.state == .dead) return;
        self.reader.feed(self.alloc, bytes) catch {
            self.setErr("out of memory buffering server output", .{});
            self.markDead();
            return;
        };
        while (true) {
            const body = self.reader.next() catch |err| {
                self.setErr("protocol framing lost ({s})", .{@errorName(err)});
                self.markDead();
                return;
            } orelse return;
            self.dispatch(body);
            if (self.state == .dead) return;
        }
    }

    fn dispatch(self: *Session, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch {
            // A single unparsable message is survivable — framing is
            // still intact, so skip it rather than kill the server.
            return;
        };
        defer parsed.deinit();
        const env = rpc.classify(parsed.value);
        switch (env.kind) {
            .invalid => {},
            .notification => self.handler.on_notification(self.handler.ctx, env.method, env.params),
            .request => self.answerServerRequest(env),
            .response => self.completeRequest(env),
        }
    }

    /// Every server->client request gets an answer. Unimplemented ones
    /// get MethodNotFound rather than silence, because a server that
    /// waits on us stops serving the user.
    fn answerServerRequest(self: *Session, env: rpc.Envelope) void {
        // The reply must echo the request's id VERBATIM — including a
        // server-minted STRING id (zls's workspace/configuration).
        // Dropping those once turned the request into a "notification"
        // nobody answered, and zls quietly stopped serving completions.
        var id_tok: std.ArrayList(u8) = .empty;
        defer id_tok.deinit(self.alloc);
        if (env.id) |i| {
            id_tok.print(self.alloc, "{d}", .{i}) catch return;
        } else if (env.id_str.len > 0) {
            appendJsonString(self.alloc, &id_tok, env.id_str) catch return;
        } else return;
        const nullable = std.mem.eql(u8, env.method, "window/workDoneProgress/create") or
            std.mem.eql(u8, env.method, "client/registerCapability") or
            std.mem.eql(u8, env.method, "client/unregisterCapability") or
            std.mem.eql(u8, env.method, "workspace/configuration");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        if (std.mem.eql(u8, env.method, "workspace/applyEdit")) {
            const applied = self.handler.on_apply_edit(self.handler.ctx, env.params);
            buf.print(
                self.alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"applied\":{s}}}}}",
                .{ id_tok.items, if (applied) "true" else "false" },
            ) catch return;
        } else if (nullable) {
            // workspace/configuration wants an ARRAY (one entry per
            // requested section); the others want a bare null.
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.alloc);
            if (std.mem.eql(u8, env.method, "workspace/configuration")) {
                appendConfigurationNulls(self.alloc, &result, env.params) catch return;
            } else {
                result.appendSlice(self.alloc, "null") catch return;
            }
            buf.print(self.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_tok.items, result.items }) catch return;
        } else {
            buf.print(
                self.alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"unsupported\"}}}}",
                .{id_tok.items},
            ) catch return;
        }
        rpc.frameInto(self.alloc, &self.out, buf.items) catch {};
    }

    /// `[null, null, …]` with one entry per requested configuration
    /// section: the result array must be the same length as
    /// `params.items` or servers log a type error and some (clangd)
    /// stop asking for anything again.
    fn appendConfigurationNulls(alloc: Allocator, out: *std.ArrayList(u8), params: std.json.Value) Allocator.Error!void {
        var n: usize = 1;
        if (params == .object) {
            if (params.object.get("items")) |items| {
                if (items == .array) n = @max(items.array.items.len, 1);
            }
        }
        try out.append(alloc, '[');
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "null");
        }
        try out.append(alloc, ']');
    }

    fn completeRequest(self: *Session, env: rpc.Envelope) void {
        const id = env.id orelse return;
        var found: ?Request = null;
        for (self.pending.items, 0..) |p, i| {
            if (p.id != id) continue;
            found = self.pending.orderedRemove(i);
            break;
        }
        const req = found orelse return;
        if (req.kind == .initialize) {
            self.absorbInitialize(env);
            return;
        }
        if (req.kind == .shutdown) {
            self.sendNotification("exit", "null");
            self.setState(.dead);
            return;
        }
        // A cancelled request's answer is dropped here rather than at
        // the call site, so no feature has to remember to check.
        if (req.cancelled) return;
        self.handler.on_response(self.handler.ctx, req, env);
    }

    fn absorbInitialize(self: *Session, env: rpc.Envelope) void {
        if (env.has_error) {
            self.setErr("initialize failed: {s}", .{env.err_message});
            self.markDead();
            return;
        }
        self.caps.deinit(self.alloc);
        self.caps = parseCaps(self.alloc, env.result);
        self.sendNotification("initialized", "{}");
        self.setState(.ready);
    }

    // ---- outbound -----------------------------------------------------

    fn sendNotification(self: *Session, method: []const u8, params_json: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        buf.print(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        ) catch return;
        rpc.frameInto(self.alloc, &self.out, buf.items) catch {};
    }

    /// Issue a request with a pre-rendered params object. Returns the
    /// record (with its id) so the caller can cancel or correlate.
    pub fn sendRequest(self: *Session, kind: Kind, method: []const u8, params_json: []const u8, meta: Request) ?Request {
        if (self.state == .dead) return null;
        var req = meta;
        req.id = self.next_id;
        req.kind = kind;
        req.seq = self.next_seq;
        self.next_id += 1;
        self.next_seq += 1;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        buf.print(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ req.id, method, params_json },
        ) catch return null;
        rpc.frameInto(self.alloc, &self.out, buf.items) catch return null;
        self.pending.append(self.alloc, req) catch return null;
        return req;
    }

    /// Mark a request cancelled and tell the server to stop. The
    /// response is still consumed (and dropped) when it arrives —
    /// forgetting the pending entry would leak the id table.
    pub fn cancel(self: *Session, id: i64) void {
        for (self.pending.items) |*p| {
            if (p.id != id or p.cancelled) continue;
            p.cancelled = true;
            var buf: [64]u8 = undefined;
            const params = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return;
            self.sendNotification("$/cancelRequest", params);
            return;
        }
    }

    /// Cancel every in-flight request of `kind` for `tab_id` — the
    /// supersede path (a new completion invalidates the previous one).
    pub fn cancelKind(self: *Session, kind: Kind, tab_id: u64) void {
        var i: usize = 0;
        while (i < self.pending.items.len) : (i += 1) {
            const p = self.pending.items[i];
            if (p.kind == kind and p.tab_id == tab_id and !p.cancelled) self.cancel(p.id);
        }
    }

    /// Drop every pending request for a tab that is going away. No
    /// `$/cancelRequest` storm: the tab's close already told the server
    /// the document is gone.
    pub fn forgetTab(self: *Session, tab_id: u64) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].tab_id == tab_id) {
                _ = self.pending.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn hasPending(self: *const Session, kind: Kind, tab_id: u64) bool {
        for (self.pending.items) |p| {
            if (p.kind == kind and p.tab_id == tab_id and !p.cancelled) return true;
        }
        return false;
    }

    // ---- lifecycle ----------------------------------------------------

    /// Send `initialize`. `root_uri` may be empty (a single file with
    /// no project); `client_pid` lets the server exit if we vanish.
    /// Pass 0 (or negative) when the server runs on ANOTHER host: our
    /// pid is meaningless there, and servers that watch `processId`
    /// (clangd does) would exit the moment they find no such process.
    pub fn start(self: *Session, root_uri: []const u8, client_pid: i32, init_options: []const u8) void {
        if (self.state != .idle) return;
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.alloc);
        if (client_pid > 0)
            params.print(self.alloc, "{{\"processId\":{d},", .{client_pid}) catch return
        else
            params.appendSlice(self.alloc, "{\"processId\":null,") catch return;
        if (root_uri.len > 0) {
            params.appendSlice(self.alloc, "\"rootUri\":") catch return;
            appendJsonString(self.alloc, &params, root_uri) catch return;
            params.appendSlice(self.alloc, ",\"workspaceFolders\":[{\"name\":\"root\",\"uri\":") catch return;
            appendJsonString(self.alloc, &params, root_uri) catch return;
            params.appendSlice(self.alloc, "}],") catch return;
        } else {
            params.appendSlice(self.alloc, "\"rootUri\":null,") catch return;
        }
        params.appendSlice(self.alloc, CLIENT_CAPS) catch return;
        // Server-specific pass-through. Only a syntactically valid JSON
        // OBJECT is forwarded: a typo in config must not make every
        // `initialize` malformed.
        if (init_options.len > 0 and isJsonObject(self.alloc, init_options)) {
            params.appendSlice(self.alloc, ",\"initializationOptions\":") catch return;
            params.appendSlice(self.alloc, init_options) catch return;
        }
        params.append(self.alloc, '}') catch return;
        _ = self.sendRequest(.initialize, "initialize", params.items, .{ .id = 0, .kind = .initialize });
        self.setState(.initializing);
    }

    /// Graceful stop. The `exit` notification follows the shutdown
    /// response (see `completeRequest`).
    pub fn stop(self: *Session) void {
        if (self.state != .ready and self.state != .initializing) return;
        _ = self.sendRequest(.shutdown, "shutdown", "null", .{ .id = 0, .kind = .shutdown });
        self.setState(.stopping);
    }

    // ---- document sync -------------------------------------------------

    pub fn didOpen(self: *Session, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) void {
        if (self.state != .ready or !self.caps.open_close) return;
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.alloc);
        p.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        appendJsonString(self.alloc, &p, uri) catch return;
        p.appendSlice(self.alloc, ",\"languageId\":") catch return;
        appendJsonString(self.alloc, &p, language_id) catch return;
        p.print(self.alloc, ",\"version\":{d},\"text\":", .{version}) catch return;
        appendJsonString(self.alloc, &p, text) catch return;
        p.appendSlice(self.alloc, "}}") catch return;
        self.sendNotification("textDocument/didOpen", p.items);
    }

    pub fn didClose(self: *Session, uri: []const u8) void {
        if (self.state != .ready or !self.caps.open_close) return;
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.alloc);
        p.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        appendJsonString(self.alloc, &p, uri) catch return;
        p.appendSlice(self.alloc, "}}") catch return;
        self.sendNotification("textDocument/didClose", p.items);
    }

    /// Incremental when the server asked for it, full otherwise.
    /// `full_text` must always be supplied: it is what a `full` server
    /// gets, and the only correct fallback if the change list is empty.
    pub fn didChange(
        self: *Session,
        uri: []const u8,
        version: i64,
        changes: []const ContentChange,
        full_text: []const u8,
    ) void {
        if (self.state != .ready or self.caps.sync == .none) return;
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.alloc);
        p.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        appendJsonString(self.alloc, &p, uri) catch return;
        p.print(self.alloc, ",\"version\":{d}}},\"contentChanges\":[", .{version}) catch return;
        if (self.caps.sync == .incremental and changes.len > 0) {
            for (changes, 0..) |ch, i| {
                if (i > 0) p.append(self.alloc, ',') catch return;
                if (ch.range) |r| {
                    p.print(
                        self.alloc,
                        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":",
                        .{ r.start.line, r.start.character, r.end.line, r.end.character },
                    ) catch return;
                } else {
                    p.appendSlice(self.alloc, "{\"text\":") catch return;
                }
                appendJsonString(self.alloc, &p, ch.text) catch return;
                p.append(self.alloc, '}') catch return;
            }
        } else {
            p.appendSlice(self.alloc, "{\"text\":") catch return;
            appendJsonString(self.alloc, &p, full_text) catch return;
            p.append(self.alloc, '}') catch return;
        }
        p.appendSlice(self.alloc, "]}") catch return;
        self.sendNotification("textDocument/didChange", p.items);
    }

    pub fn didSave(self: *Session, uri: []const u8, text: []const u8) void {
        if (self.state != .ready or !self.caps.save_notify) return;
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.alloc);
        p.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        appendJsonString(self.alloc, &p, uri) catch return;
        p.appendSlice(self.alloc, "}") catch return;
        if (self.caps.save_include_text) {
            p.appendSlice(self.alloc, ",\"text\":") catch return;
            appendJsonString(self.alloc, &p, text) catch return;
        }
        p.appendSlice(self.alloc, "}") catch return;
        self.sendNotification("textDocument/didSave", p.items);
    }
};

fn isJsonObject(alloc: Allocator, text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

/// The client capabilities sketerm advertises. A constant rather than a
/// builder: every field is a fact about this editor, none of them
/// depend on runtime state, and keeping it as one literal makes it easy
/// to audit against what the features actually implement.
pub const CLIENT_CAPS =
    \\"clientInfo":{"name":"sketerm"},
    \\"capabilities":{
    \\"general":{"positionEncodings":["utf-8","utf-16"]},
    \\"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true},"symbol":{"dynamicRegistration":false},"configuration":true,"executeCommand":{"dynamicRegistration":false}},
    \\"textDocument":{
    \\"synchronization":{"dynamicRegistration":false,"willSave":false,"didSave":true},
    \\"publishDiagnostics":{"relatedInformation":true,"versionSupport":true},
    \\"completion":{"dynamicRegistration":false,"contextSupport":true,"completionItem":{"snippetSupport":false,"documentationFormat":["plaintext","markdown"],"resolveSupport":{"properties":["documentation","detail","additionalTextEdits"]}}},
    \\"hover":{"dynamicRegistration":false,"contentFormat":["plaintext","markdown"]},
    \\"definition":{"dynamicRegistration":false,"linkSupport":true},
    \\"declaration":{"dynamicRegistration":false,"linkSupport":true},
    \\"typeDefinition":{"dynamicRegistration":false,"linkSupport":true},
    \\"references":{"dynamicRegistration":false},
    \\"documentSymbol":{"dynamicRegistration":false,"hierarchicalDocumentSymbolSupport":true},
    \\"rename":{"dynamicRegistration":false,"prepareSupport":false},
    \\"formatting":{"dynamicRegistration":false},
    \\"rangeFormatting":{"dynamicRegistration":false},
    \\"signatureHelp":{"dynamicRegistration":false,"contextSupport":true,"signatureInformation":{"documentationFormat":["plaintext","markdown"],"parameterInformation":{"labelOffsetSupport":true},"activeParameterSupport":true}},
    \\"codeAction":{"dynamicRegistration":false,"isPreferredSupport":true,"dataSupport":true,"resolveSupport":{"properties":["edit"]},"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["","quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source","source.organizeImports","source.fixAll"]}}},
    \\"inlayHint":{"dynamicRegistration":false,"resolveSupport":{"properties":[]}},
    \\"semanticTokens":{"dynamicRegistration":false,"requests":{"range":false,"full":{"delta":true}},"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":true,"augmentsSyntaxTokens":true}
    \\}}
;

/// Pull the capability flags out of an `initialize` result.
pub fn parseCaps(alloc: Allocator, result: std.json.Value) Caps {
    var caps = Caps{};
    const root = switch (result) {
        .object => |o| o,
        else => return caps,
    };
    if (root.get("positionEncoding")) |pe| {
        if (pe == .string) caps.encoding = Encoding.fromWire(pe.string);
    }
    const sc = switch (root.get("capabilities") orelse std.json.Value.null) {
        .object => |o| o,
        else => return caps,
    };

    // textDocumentSync is either a number (legacy) or an object.
    if (sc.get("textDocumentSync")) |ts| {
        switch (ts) {
            .integer => |i| {
                caps.sync = syncFromInt(i);
                caps.open_close = caps.sync != .none;
            },
            .object => |o| {
                caps.open_close = boolOf(o.get("openClose"), false);
                if (o.get("change")) |ch| {
                    if (ch == .integer) caps.sync = syncFromInt(ch.integer);
                }
                if (o.get("save")) |sv| {
                    switch (sv) {
                        .bool => |b| caps.save_notify = b,
                        .object => |so| {
                            caps.save_notify = true;
                            caps.save_include_text = boolOf(so.get("includeText"), false);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (sc.get("completionProvider")) |cp| {
        if (cp == .object) {
            caps.completion = true;
            caps.completion_resolve = boolOf(cp.object.get("resolveProvider"), false);
            caps.completion_triggers = firstCharsOf(alloc, cp.object.get("triggerCharacters"));
        }
    }

    if (sc.get("signatureHelpProvider")) |sp| {
        if (sp == .object) {
            caps.signature_help = true;
            caps.signature_triggers = firstCharsOf(alloc, sp.object.get("triggerCharacters"));
            caps.signature_retriggers = firstCharsOf(alloc, sp.object.get("retriggerCharacters"));
        }
    }

    if (sc.get("codeActionProvider")) |ca| {
        caps.code_action = providerOn(ca);
        if (ca == .object) caps.code_action_resolve = boolOf(ca.object.get("resolveProvider"), false);
    }
    caps.inlay_hint = providerOn(sc.get("inlayHintProvider"));

    // `semanticTokensProvider.full` is `true` or `{delta}`; a provider
    // that offers only `range` is treated as offering nothing, because
    // the client asks for the whole document first (docs/lsp.md).
    if (sc.get("semanticTokensProvider")) |sp| {
        if (sp == .object) {
            if (sp.object.get("full")) |full| {
                switch (full) {
                    .bool => |b| caps.semantic_tokens = b,
                    .object => |fo| {
                        caps.semantic_tokens = true;
                        caps.semantic_tokens_delta = boolOf(fo.get("delta"), false);
                    },
                    else => {},
                }
            }
            if (caps.semantic_tokens) caps.token_types.absorb(alloc, sp);
        }
    }
    caps.hover = providerOn(sc.get("hoverProvider"));
    caps.definition = providerOn(sc.get("definitionProvider"));
    caps.declaration = providerOn(sc.get("declarationProvider"));
    caps.type_definition = providerOn(sc.get("typeDefinitionProvider"));
    caps.references = providerOn(sc.get("referencesProvider"));
    caps.document_symbol = providerOn(sc.get("documentSymbolProvider"));
    caps.workspace_symbol = providerOn(sc.get("workspaceSymbolProvider"));
    caps.rename = providerOn(sc.get("renameProvider"));
    caps.formatting = providerOn(sc.get("documentFormattingProvider"));
    caps.range_formatting = providerOn(sc.get("documentRangeFormattingProvider"));
    return caps;
}

/// The FIRST byte of each string in a `triggerCharacters`-shaped array.
/// A trigger is matched against one committed byte, so a multi-byte
/// trigger would never fire anyway; taking the lead byte at least makes
/// an ASCII trigger in a list containing one work.
fn firstCharsOf(alloc: Allocator, v: ?std.json.Value) []u8 {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var buf: std.ArrayList(u8) = .empty;
    for (val.array.items) |t| {
        if (t == .string and t.string.len > 0) buf.append(alloc, t.string[0]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
}

fn syncFromInt(i: i64) SyncKind {
    return switch (i) {
        1 => .full,
        2 => .incremental,
        else => .none,
    };
}

/// A provider is on when it is `true` or an options OBJECT — `false`,
/// `null` and absent all mean off.
fn providerOn(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

fn boolOf(v: ?std.json.Value, dflt: bool) bool {
    const val = v orelse return dflt;
    return switch (val) {
        .bool => |b| b,
        else => dflt,
    };
}

/// Append `s` as a JSON string literal. Control characters below 0x20
/// are escaped (\u00XX); everything else, including all of UTF-8, goes
/// through verbatim — the wire is UTF-8 and escaping non-ASCII would
/// only make the payload bigger.
pub fn appendJsonString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0C => try out.appendSlice(alloc, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const e = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{ch}) catch unreachable;
                try out.appendSlice(alloc, e);
            },
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

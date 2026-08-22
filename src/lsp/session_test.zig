//! Session-level protocol tests driven by an in-process scripted
//! server: bytes the Session emits are decoded here, and canned replies
//! are fed straight back into `Session.feed`. No process, no pipe, no
//! GTK — so the whole lifecycle, capability negotiation, staleness and
//! cancellation surface is covered in `zig build test-core`.

const std = @import("std");
const testing = std.testing;
const rpc = @import("rpc.zig");
const session = @import("session.zig");
const pos = @import("position.zig");
const Session = session.Session;

/// Collects everything the session hands back so a test can assert on
/// it, and decodes the session's outbound frames.
const Recorder = struct {
    alloc: std.mem.Allocator,
    responses: std.ArrayList(struct { req: session.Request, ok: bool, text: []u8 }) = .empty,
    notifications: std.ArrayList([]u8) = .empty,
    states: std.ArrayList(session.State) = .empty,
    /// `workspace/applyEdit` payloads the server pushed at us.
    applied: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Recorder) void {
        for (self.responses.items) |r| self.alloc.free(r.text);
        self.responses.deinit(self.alloc);
        for (self.notifications.items) |n| self.alloc.free(n);
        self.notifications.deinit(self.alloc);
        for (self.applied.items) |a| self.alloc.free(a);
        self.applied.deinit(self.alloc);
        self.states.deinit(self.alloc);
    }

    fn handler(self: *Recorder) session.Handler {
        return .{
            .ctx = self,
            .on_response = onResponse,
            .on_notification = onNotification,
            .on_state = onState,
            .on_apply_edit = onApplyEdit,
        };
    }

    fn onApplyEdit(ctx: *anyopaque, params: std.json.Value) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var w: std.Io.Writer.Allocating = .init(self.alloc);
        defer w.deinit();
        std.json.Stringify.value(params, .{}, &w.writer) catch return false;
        const txt = self.alloc.dupe(u8, w.written()) catch return false;
        self.applied.append(self.alloc, txt) catch {
            self.alloc.free(txt);
            return false;
        };
        return true;
    }

    fn onResponse(ctx: *anyopaque, req: session.Request, env: rpc.Envelope) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var buf: std.ArrayList(u8) = .empty;
        if (env.has_error) {
            buf.appendSlice(self.alloc, env.err_message) catch {};
        } else {
            var w: std.Io.Writer.Allocating = .init(self.alloc);
            defer w.deinit();
            std.json.Stringify.value(env.result, .{}, &w.writer) catch {};
            buf.appendSlice(self.alloc, w.written()) catch {};
        }
        const text = buf.toOwnedSlice(self.alloc) catch return;
        self.responses.append(self.alloc, .{ .req = req, .ok = !env.has_error, .text = text }) catch {};
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value) void {
        _ = params;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const dup = self.alloc.dupe(u8, method) catch return;
        self.notifications.append(self.alloc, dup) catch self.alloc.free(dup);
    }

    fn onState(ctx: *anyopaque, state: session.State) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.states.append(self.alloc, state) catch {};
    }
};

/// One decoded outbound message.
const Sent = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *Sent) void {
        self.parsed.deinit();
    }
    fn method(self: *const Sent) []const u8 {
        const m = self.parsed.value.object.get("method") orelse return "";
        return switch (m) {
            .string => |s| s,
            else => "",
        };
    }
    fn id(self: *const Sent) ?i64 {
        const v = self.parsed.value.object.get("id") orelse return null;
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    fn params(self: *const Sent) std.json.Value {
        return self.parsed.value.object.get("params") orelse .null;
    }
};

/// Decode and CONSUME everything the session queued for the server.
fn drain(alloc: std.mem.Allocator, s: *Session, out: *std.ArrayList(Sent)) !void {
    var r = rpc.Reader{};
    defer r.deinit(alloc);
    try r.feed(alloc, s.out.items);
    s.out.clearRetainingCapacity();
    while (try r.next()) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        try out.append(alloc, .{ .parsed = parsed });
    }
}

fn freeSent(alloc: std.mem.Allocator, list: *std.ArrayList(Sent)) void {
    for (list.items) |*s| s.deinit();
    list.deinit(alloc);
}

fn feedJson(s: *Session, alloc: std.mem.Allocator, body: []const u8) !void {
    const framed = try rpc.frame(alloc, body);
    defer alloc.free(framed);
    s.feed(framed);
}

const FULL_CAPS =
    \\{"positionEncoding":"utf-16","capabilities":{
    \\"textDocumentSync":{"openClose":true,"change":2,"save":{"includeText":false}},
    \\"completionProvider":{"resolveProvider":true,"triggerCharacters":[".",":"]},
    \\"hoverProvider":true,"definitionProvider":true,"declarationProvider":true,
    \\"typeDefinitionProvider":true,"referencesProvider":true,
    \\"documentSymbolProvider":true,"workspaceSymbolProvider":true,
    \\"renameProvider":{"prepareProvider":false},
    \\"documentFormattingProvider":true,"documentRangeFormattingProvider":true,
    \\"signatureHelpProvider":{"triggerCharacters":["(","<"],"retriggerCharacters":[","]},
    \\"codeActionProvider":{"resolveProvider":true},
    \\"inlayHintProvider":{"resolveProvider":false},
    \\"semanticTokensProvider":{"legend":{"tokenTypes":["namespace","type","function"],"tokenModifiers":["static"]},"full":{"delta":true},"range":true}}}
;

/// Bring a session all the way to `.ready` with the full capability set.
fn readySession(alloc: std.mem.Allocator, s: *Session) !void {
    s.start("file:///proj", 1234, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, s, &sent);
    try testing.expectEqualStrings("initialize", sent.items[0].method());
    const id = sent.items[0].id().?;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.print(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, FULL_CAPS });
    try feedJson(s, alloc, body.items);
}

/// Recorder + Session + the decode buffer every test here needs.
///
/// The handler holds a pointer to `rec`, so this is initialised IN PLACE
/// (`var fx: Fixture = undefined; fx.init();`) and never copied.
const Fixture = struct {
    alloc: std.mem.Allocator,
    rec: Recorder,
    s: Session,
    sent: std.ArrayList(Sent),

    fn init(self: *Fixture) void {
        self.alloc = testing.allocator;
        self.rec = .{ .alloc = self.alloc };
        self.s = Session.init(self.alloc, self.rec.handler());
        self.sent = .empty;
    }

    fn deinit(self: *Fixture) void {
        freeSent(self.alloc, &self.sent);
        self.s.deinit();
        self.rec.deinit();
    }

    /// Decode and CONSUME everything queued for the server.
    ///
    /// The batch is owned by the fixture, so a second call FREES what the
    /// first returned: read one batch out before draining again.
    fn drainSent(self: *Fixture) !*std.ArrayList(Sent) {
        for (self.sent.items) |*m| m.deinit();
        self.sent.clearRetainingCapacity();
        try drain(self.alloc, &self.s, &self.sent);
        return &self.sent;
    }

    /// Handshake all the way to `.ready` with the full capability set.
    fn ready(self: *Fixture) !void {
        try readySession(self.alloc, &self.s);
    }

    /// Start and discard the `initialize` frame, leaving the caller to
    /// answer it with the capability set the test is about.
    fn boot(self: *Fixture) !void {
        self.s.start("", 1, "");
        _ = try self.drainSent();
    }

    fn feed(self: *Fixture, body: []const u8) !void {
        try feedJson(&self.s, self.alloc, body);
    }
};

test "session: initialize handshake reaches ready and sends initialized" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    try fx.ready();
    try testing.expectEqual(session.State.ready, fx.s.state);
    const sent = try fx.drainSent();
    try testing.expectEqualStrings("initialized", sent.items[0].method());
    try testing.expectEqual(session.State.initializing, fx.rec.states.items[0]);
    try testing.expectEqual(session.State.ready, fx.rec.states.items[1]);
}

test "session: a non-positive client pid initializes with processId null" {
    // The remote transport passes 0: our pid means nothing on the
    // server's host, and servers that watch processId (clangd) exit
    // when the advertised pid does not exist there.
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    fx.s.start("file:///proj", 0, "");
    const sent = try fx.drainSent();
    try testing.expectEqualStrings("initialize", sent.items[0].method());
    const pid_field = sent.items[0].params().object.get("processId") orelse return error.TestExpectedField;
    try testing.expect(pid_field == .null);
}

test "session: capabilities are absorbed exactly" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();

    try testing.expectEqual(pos.Encoding.utf16, fx.s.caps.encoding);
    try testing.expectEqual(session.SyncKind.incremental, fx.s.caps.sync);
    try testing.expect(fx.s.caps.open_close);
    try testing.expect(fx.s.caps.save_notify);
    try testing.expect(!fx.s.caps.save_include_text);
    try testing.expect(fx.s.caps.completion and fx.s.caps.completion_resolve);
    try testing.expect(fx.s.caps.isTrigger('.') and fx.s.caps.isTrigger(':'));
    try testing.expect(!fx.s.caps.isTrigger('x'));
    try testing.expect(fx.s.caps.hover and fx.s.caps.definition and fx.s.caps.declaration);
    try testing.expect(fx.s.caps.type_definition and fx.s.caps.references);
    try testing.expect(fx.s.caps.document_symbol and fx.s.caps.workspace_symbol);
    try testing.expect(fx.s.caps.rename and fx.s.caps.formatting and fx.s.caps.range_formatting);
    try testing.expect(fx.s.caps.signature_help);
    try testing.expect(fx.s.caps.isSignatureTrigger('(') and fx.s.caps.isSignatureTrigger('<'));
    try testing.expect(!fx.s.caps.isSignatureTrigger(','));
    try testing.expect(fx.s.caps.isSignatureRetrigger(','));
    try testing.expect(fx.s.caps.code_action and fx.s.caps.code_action_resolve);
    try testing.expect(fx.s.caps.inlay_hint);
    try testing.expect(fx.s.caps.semantic_tokens and fx.s.caps.semantic_tokens_delta);
    try testing.expectEqualStrings("type", fx.s.caps.token_types.name(1));
    try testing.expectEqualStrings("", fx.s.caps.token_types.name(7));
}

test "session: a semanticTokens provider offering only range is still a provider" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"],"tokenModifiers":["readonly"]},"range":true}}}}
    );
    try testing.expect(!fx.s.caps.semantic_tokens);
    try testing.expect(!fx.s.caps.semantic_tokens_delta);
    try testing.expect(fx.s.caps.semantic_tokens_range);
    // The legend must survive: a range-only provider's tokens are
    // decoded through exactly the same table.
    try testing.expectEqual(@as(usize, 1), fx.s.caps.token_types.types.items.len);
    try testing.expectEqualStrings("readonly", fx.s.caps.token_types.modName(0));
}

test "session: an options-object range provider counts, a false one does not" {
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"]},"range":{}}}}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"]},"range":false}}}}
        ,
    }, 0..) |msg, i| {
        var fx: Fixture = undefined;
        fx.init();
        defer fx.deinit();
        try fx.boot();
        try fx.feed(msg);
        try testing.expectEqual(i == 0, fx.s.caps.semantic_tokens_range);
    }
}

test "session: inlayHintProvider.resolveProvider is picked up" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"inlayHintProvider":{"resolveProvider":true}}}}
    );
    try testing.expect(fx.s.caps.inlay_hint);
    try testing.expect(fx.s.caps.inlay_hint_resolve);
}

test "session: a bare-true inlayHintProvider offers no resolve" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"inlayHintProvider":true}}}
    );
    try testing.expect(fx.s.caps.inlay_hint);
    try testing.expect(!fx.s.caps.inlay_hint_resolve);
}

test "session: the client advertises what these features actually need" {
    // A capability we send but do not implement is a lie a server acts
    // on; one we implement but do not send is a feature that silently
    // never arrives.
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"range\":true") != null);
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"tooltip\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"readonly\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"deprecated\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"defaultLibrary\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"versionSupport\":true") != null);
}

test "session: the new capabilities default to off" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    try testing.expect(!fx.s.caps.signature_help);
    try testing.expect(!fx.s.caps.code_action);
    try testing.expect(!fx.s.caps.inlay_hint);
    try testing.expect(!fx.s.caps.inlay_hint_resolve);
    try testing.expect(!fx.s.caps.semantic_tokens);
    try testing.expect(!fx.s.caps.semantic_tokens_range);
    try testing.expectEqual(@as(usize, 0), fx.s.caps.signature_triggers.len);
}

test "session: workspace/applyEdit is answered with the handler's verdict" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    _ = try fx.drainSent(); // "initialized"

    // A command-carrying code action ends here: the SERVER asks US to
    // write. It is a request, so it must be answered or the server
    // blocks forever.
    try fx.feed(
        \\{"jsonrpc":"2.0","id":88,"method":"workspace/applyEdit","params":{"edit":{"changes":{"file:///a.zig":[]}}}}
    );
    const reply = try fx.drainSent();
    try testing.expectEqual(@as(usize, 1), reply.items.len);
    try testing.expectEqual(@as(i64, 88), reply.items[0].id().?);
    const result = reply.items[0].parsed.value.object.get("result").?;
    try testing.expect(result.object.get("applied").?.bool);
    // The handler saw the params, edit included.
    try testing.expectEqual(@as(usize, 1), fx.rec.applied.items.len);
    try testing.expect(std.mem.indexOf(u8, fx.rec.applied.items[0], "file:///a.zig") != null);
}

test "session: an empty capability set disables every feature" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    try testing.expectEqual(session.State.ready, fx.s.state);
    try testing.expect(!fx.s.caps.completion);
    try testing.expect(!fx.s.caps.open_close);
    try testing.expectEqual(session.SyncKind.none, fx.s.caps.sync);
    // Sync is off, so didOpen/didChange emit NOTHING rather than
    // desynchronising a server that never asked for documents.
    fx.s.didOpen("file:///a.zig", "zig", 1, "x");
    fx.s.didChange("file:///a.zig", 2, &.{}, "y");
    const after = try fx.drainSent();
    try testing.expectEqual(@as(usize, 1), after.items.len); // just "initialized"
}

test "session: positionEncoding utf-8 is honoured when offered" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"result":{"positionEncoding":"utf-8","capabilities":{}}}
    );
    try testing.expectEqual(pos.Encoding.utf8, fx.s.caps.encoding);
    // And the client advertised that it can speak it.
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"utf-8\"") != null);
}

test "session: initialize failure kills the session instead of hanging" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}
    );
    try testing.expectEqual(session.State.dead, fx.s.state);
    try testing.expect(std.mem.indexOf(u8, fx.s.errText(), "boom") != null);
}

test "session: incremental didChange carries ranges in array order" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();

    const changes = [_]session.ContentChange{
        .{ .range = .{ .start = .{ .line = 3, .character = 2 }, .end = .{ .line = 3, .character = 5 } }, .text = "AB" },
        .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } }, .text = "\n" },
    };
    fx.s.didChange("file:///a.zig", 7, &changes, "IGNORED");
    const sent = try fx.drainSent();
    try testing.expectEqualStrings("textDocument/didChange", sent.items[0].method());
    const p = sent.items[0].params().object;
    try testing.expectEqual(@as(i64, 7), p.get("textDocument").?.object.get("version").?.integer);
    const arr = p.get("contentChanges").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqual(@as(i64, 3), arr.items[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);
    try testing.expectEqualStrings("AB", arr.items[0].object.get("text").?.string);
    // Escaping is real JSON, not a literal newline in the payload.
    try testing.expectEqualStrings("\n", arr.items[1].object.get("text").?.string);
}

test "session: a full-sync server gets the whole document, never the ranges" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.boot();
    try fx.feed(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}
    );
    try testing.expectEqual(session.SyncKind.full, fx.s.caps.sync);
    try testing.expect(fx.s.caps.open_close);
    fx.s.out.clearRetainingCapacity();
    const changes = [_]session.ContentChange{
        .{ .range = .{}, .text = "x" },
    };
    fx.s.didChange("file:///a.zig", 2, &changes, "WHOLE TEXT");
    const sent = try fx.drainSent();
    const arr = sent.items[0].params().object.get("contentChanges").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expect(arr.items[0].object.get("range") == null);
    try testing.expectEqualStrings("WHOLE TEXT", arr.items[0].object.get("text").?.string);
}

test "session: didOpen escapes control characters and multibyte text survives" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();
    fx.s.didOpen("file:///a.zig", "zig", 1, "a\t\"b\"\n\u{1F600}\x01");
    const sent = try fx.drainSent();
    const td = sent.items[0].params().object.get("textDocument").?.object;
    try testing.expectEqualStrings("a\t\"b\"\n\u{1F600}\x01", td.get("text").?.string);
    try testing.expectEqualStrings("zig", td.get("languageId").?.string);
}

test "session: a stale response still carries the revision it was built for" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();

    const req = fx.s.sendRequest(.hover, "textDocument/hover", "{}", .{
        .id = 0,
        .kind = .hover,
        .tab_id = 42,
        .revision = 11,
    }).?;
    _ = try fx.drainSent();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(fx.alloc);
    try body.print(fx.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":1}}}}", .{req.id});
    try fx.feed(body.items);
    try testing.expectEqual(@as(usize, 1), fx.rec.responses.items.len);
    try testing.expectEqual(@as(u64, 11), fx.rec.responses.items[0].req.revision);
    try testing.expectEqual(@as(u64, 42), fx.rec.responses.items[0].req.tab_id);
    try testing.expectEqual(session.Kind.hover, fx.rec.responses.items[0].req.kind);
}

test "session: cancelling suppresses the answer and sends $/cancelRequest" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();

    const a = fx.s.sendRequest(.completion, "textDocument/completion", "{}", .{ .id = 0, .kind = .completion, .tab_id = 1, .revision = 1 }).?;
    try testing.expect(fx.s.hasPending(.completion, 1));
    fx.s.cancelKind(.completion, 1);
    try testing.expect(!fx.s.hasPending(.completion, 1));

    const sent = try fx.drainSent();
    var saw_cancel = false;
    for (sent.items) |*m| {
        if (std.mem.eql(u8, m.method(), "$/cancelRequest")) {
            saw_cancel = true;
            try testing.expectEqual(a.id, m.params().object.get("id").?.integer);
        }
    }
    try testing.expect(saw_cancel);

    // The late answer is consumed and dropped, not forwarded.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(fx.alloc);
    try body.print(fx.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{a.id});
    try fx.feed(body.items);
    try testing.expectEqual(@as(usize, 0), fx.rec.responses.items.len);
    try testing.expectEqual(@as(usize, 0), fx.s.pending.items.len);
}

test "session: forgetTab drops that tab's requests only" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    _ = fx.s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover, .tab_id = 1 });
    _ = fx.s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover, .tab_id = 2 });
    fx.s.forgetTab(1);
    try testing.expect(!fx.s.hasPending(.hover, 1));
    try testing.expect(fx.s.hasPending(.hover, 2));
}

test "session: server-to-client requests are always answered" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();

    try fx.feed(
        \\{"jsonrpc":"2.0","id":88,"method":"window/workDoneProgress/create","params":{"token":"t"}}
    );
    try fx.feed(
        \\{"jsonrpc":"2.0","id":89,"method":"workspace/configuration","params":{"items":[{"section":"a"},{"section":"b"}]}}
    );
    // Not `workspace/applyEdit` any more: that one IS implemented now
    // (it is how a command-carrying code action does its work).
    try fx.feed(
        \\{"jsonrpc":"2.0","id":90,"method":"workspace/codeLens/refresh","params":{}}
    );
    const sent = try fx.drainSent();
    try testing.expectEqual(@as(usize, 3), sent.items.len);
    try testing.expectEqual(@as(i64, 88), sent.items[0].id().?);
    try testing.expectEqual(std.json.Value.null, sent.items[0].parsed.value.object.get("result").?);
    // One null per requested section.
    try testing.expectEqual(@as(usize, 2), sent.items[1].parsed.value.object.get("result").?.array.items.len);
    // Unimplemented gets a real error, so the server stops waiting.
    try testing.expect(sent.items[2].parsed.value.object.get("error") != null);
}

test "session: a string request id is echoed back verbatim" {
    // zls sends workspace/configuration with id "i_haz_configuration"
    // and matches the answer by that exact id. Dropping or rewriting
    // it leaves zls waiting forever — it then returns null for every
    // completion request.
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();

    try fx.feed(
        \\{"jsonrpc":"2.0","id":"i_haz_configuration","method":"workspace/configuration","params":{"items":[{"section":"zls"}]}}
    );
    const sent = try fx.drainSent();
    try testing.expectEqual(@as(usize, 1), sent.items.len);
    const reply = sent.items[0].parsed.value.object;
    try testing.expectEqualStrings("i_haz_configuration", reply.get("id").?.string);
    try testing.expectEqual(@as(usize, 1), reply.get("result").?.array.items.len);
}

test "session: notifications reach the handler" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    try fx.feed(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.zig","diagnostics":[]}}
    );
    try testing.expectEqual(@as(usize, 1), fx.rec.notifications.items.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", fx.rec.notifications.items[0]);
}

test "session: shutdown is followed by exit and the dead state" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.out.clearRetainingCapacity();
    fx.s.stop();
    const sent = try fx.drainSent();
    try testing.expectEqualStrings("shutdown", sent.items[0].method());
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(fx.alloc);
    try body.print(fx.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{sent.items[0].id().?});
    try fx.feed(body.items);
    try testing.expectEqual(session.State.dead, fx.s.state);
    const after = try fx.drainSent();
    try testing.expectEqualStrings("exit", after.items[0].method());
}

test "session: lost framing kills the session rather than desynchronising" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.feed("garbage without a header\r\n\r\nmore");
    try testing.expectEqual(session.State.dead, fx.s.state);
    try testing.expect(std.mem.indexOf(u8, fx.s.errText(), "framing") != null);
}

test "session: an unparsable message is skipped, framing is kept" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    try fx.feed("{not json");
    try testing.expectEqual(session.State.ready, fx.s.state);
    try fx.feed(
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{}}
    );
    try testing.expectEqual(@as(usize, 1), fx.rec.notifications.items.len);
}

test "session: requests are refused once the session is dead" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    fx.s.markDead();
    try testing.expect(fx.s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover }) == null);
}

test "session: a dead server leaves no request in flight" {
    // The outline panel asks "is my documentSymbol still out there?"
    // instead of keeping a pending flag, so a server that dies with one
    // outstanding must not look like it is still thinking — that is
    // what once left a tab never asking for symbols again.
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    _ = fx.s.sendRequest(.document_symbol, "textDocument/documentSymbol", "{}", .{
        .id = 0,
        .kind = .document_symbol,
        .tab_id = 4,
    });
    try testing.expect(fx.s.hasPending(.document_symbol, 4));
    try testing.expect(!fx.s.hasPending(.document_symbol, 5));
    fx.s.markDead();
    try testing.expect(!fx.s.hasPending(.document_symbol, 4));
}

test "session: a closing tab leaves no request in flight" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    try fx.ready();
    _ = fx.s.sendRequest(.document_symbol, "textDocument/documentSymbol", "{}", .{
        .id = 0,
        .kind = .document_symbol,
        .tab_id = 6,
    });
    try testing.expect(fx.s.hasPending(.document_symbol, 6));
    fx.s.forgetTab(6);
    try testing.expect(!fx.s.hasPending(.document_symbol, 6));
}

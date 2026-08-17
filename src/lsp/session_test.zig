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

test "session: initialize handshake reaches ready and sends initialized" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();

    try readySession(alloc, &s);
    try testing.expectEqual(session.State.ready, s.state);
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try testing.expectEqualStrings("initialized", sent.items[0].method());
    try testing.expectEqual(session.State.initializing, rec.states.items[0]);
    try testing.expectEqual(session.State.ready, rec.states.items[1]);
}

test "session: a non-positive client pid initializes with processId null" {
    // The remote transport passes 0: our pid means nothing on the
    // server's host, and servers that watch processId (clangd) exit
    // when the advertised pid does not exist there.
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("file:///proj", 0, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try testing.expectEqualStrings("initialize", sent.items[0].method());
    const pid_field = sent.items[0].params().object.get("processId") orelse return error.TestExpectedField;
    try testing.expect(pid_field == .null);
}

test "session: capabilities are absorbed exactly" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);

    try testing.expectEqual(pos.Encoding.utf16, s.caps.encoding);
    try testing.expectEqual(session.SyncKind.incremental, s.caps.sync);
    try testing.expect(s.caps.open_close);
    try testing.expect(s.caps.save_notify);
    try testing.expect(!s.caps.save_include_text);
    try testing.expect(s.caps.completion and s.caps.completion_resolve);
    try testing.expect(s.caps.isTrigger('.') and s.caps.isTrigger(':'));
    try testing.expect(!s.caps.isTrigger('x'));
    try testing.expect(s.caps.hover and s.caps.definition and s.caps.declaration);
    try testing.expect(s.caps.type_definition and s.caps.references);
    try testing.expect(s.caps.document_symbol and s.caps.workspace_symbol);
    try testing.expect(s.caps.rename and s.caps.formatting and s.caps.range_formatting);
    try testing.expect(s.caps.signature_help);
    try testing.expect(s.caps.isSignatureTrigger('(') and s.caps.isSignatureTrigger('<'));
    try testing.expect(!s.caps.isSignatureTrigger(','));
    try testing.expect(s.caps.isSignatureRetrigger(','));
    try testing.expect(s.caps.code_action and s.caps.code_action_resolve);
    try testing.expect(s.caps.inlay_hint);
    try testing.expect(s.caps.semantic_tokens and s.caps.semantic_tokens_delta);
    try testing.expectEqualStrings("type", s.caps.token_types.name(1));
    try testing.expectEqualStrings("", s.caps.token_types.name(7));
}

test "session: a semanticTokens provider offering only range is still a provider" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"],"tokenModifiers":["readonly"]},"range":true}}}}
    );
    try testing.expect(!s.caps.semantic_tokens);
    try testing.expect(!s.caps.semantic_tokens_delta);
    try testing.expect(s.caps.semantic_tokens_range);
    // The legend must survive: a range-only provider's tokens are
    // decoded through exactly the same table.
    try testing.expectEqual(@as(usize, 1), s.caps.token_types.types.items.len);
    try testing.expectEqualStrings("readonly", s.caps.token_types.modName(0));
}

test "session: an options-object range provider counts, a false one does not" {
    const alloc = testing.allocator;
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"]},"range":{}}}}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"]},"range":false}}}}
        ,
    }, 0..) |msg, i| {
        var rec = Recorder{ .alloc = alloc };
        defer rec.deinit();
        var s = Session.init(alloc, rec.handler());
        defer s.deinit();
        s.start("", 1, "");
        var sent: std.ArrayList(Sent) = .empty;
        defer freeSent(alloc, &sent);
        try drain(alloc, &s, &sent);
        try feedJson(&s, alloc, msg);
        try testing.expectEqual(i == 0, s.caps.semantic_tokens_range);
    }
}

test "session: inlayHintProvider.resolveProvider is picked up" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"inlayHintProvider":{"resolveProvider":true}}}}
    );
    try testing.expect(s.caps.inlay_hint);
    try testing.expect(s.caps.inlay_hint_resolve);
}

test "session: a bare-true inlayHintProvider offers no resolve" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"inlayHintProvider":true}}}
    );
    try testing.expect(s.caps.inlay_hint);
    try testing.expect(!s.caps.inlay_hint_resolve);
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
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    try testing.expect(!s.caps.signature_help);
    try testing.expect(!s.caps.code_action);
    try testing.expect(!s.caps.inlay_hint);
    try testing.expect(!s.caps.inlay_hint_resolve);
    try testing.expect(!s.caps.semantic_tokens);
    try testing.expect(!s.caps.semantic_tokens_range);
    try testing.expectEqual(@as(usize, 0), s.caps.signature_triggers.len);
}

test "session: workspace/applyEdit is answered with the handler's verdict" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent); // "initialized"

    // A command-carrying code action ends here: the SERVER asks US to
    // write. It is a request, so it must be answered or the server
    // blocks forever.
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":88,"method":"workspace/applyEdit","params":{"edit":{"changes":{"file:///a.zig":[]}}}}
    );
    var reply: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &reply);
    try drain(alloc, &s, &reply);
    try testing.expectEqual(@as(usize, 1), reply.items.len);
    try testing.expectEqual(@as(i64, 88), reply.items[0].id().?);
    const result = reply.items[0].parsed.value.object.get("result").?;
    try testing.expect(result.object.get("applied").?.bool);
    // The handler saw the params, edit included.
    try testing.expectEqual(@as(usize, 1), rec.applied.items.len);
    try testing.expect(std.mem.indexOf(u8, rec.applied.items[0], "file:///a.zig") != null);
}

test "session: an empty capability set disables every feature" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    try testing.expectEqual(session.State.ready, s.state);
    try testing.expect(!s.caps.completion);
    try testing.expect(!s.caps.open_close);
    try testing.expectEqual(session.SyncKind.none, s.caps.sync);
    // Sync is off, so didOpen/didChange emit NOTHING rather than
    // desynchronising a server that never asked for documents.
    s.didOpen("file:///a.zig", "zig", 1, "x");
    s.didChange("file:///a.zig", 2, &.{}, "y");
    var after: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &after);
    try drain(alloc, &s, &after);
    try testing.expectEqual(@as(usize, 1), after.items.len); // just "initialized"
}

test "session: positionEncoding utf-8 is honoured when offered" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"positionEncoding":"utf-8","capabilities":{}}}
    );
    try testing.expectEqual(pos.Encoding.utf8, s.caps.encoding);
    // And the client advertised that it can speak it.
    try testing.expect(std.mem.indexOf(u8, session.CLIENT_CAPS, "\"utf-8\"") != null);
}

test "session: initialize failure kills the session instead of hanging" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}
    );
    try testing.expectEqual(session.State.dead, s.state);
    try testing.expect(std.mem.indexOf(u8, s.errText(), "boom") != null);
}

test "session: incremental didChange carries ranges in array order" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();

    const changes = [_]session.ContentChange{
        .{ .range = .{ .start = .{ .line = 3, .character = 2 }, .end = .{ .line = 3, .character = 5 } }, .text = "AB" },
        .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } }, .text = "\n" },
    };
    s.didChange("file:///a.zig", 7, &changes, "IGNORED");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
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
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    s.start("", 1, "");
    var boot: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &boot);
    try drain(alloc, &s, &boot);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}
    );
    try testing.expectEqual(session.SyncKind.full, s.caps.sync);
    try testing.expect(s.caps.open_close);
    s.out.clearRetainingCapacity();
    const changes = [_]session.ContentChange{
        .{ .range = .{}, .text = "x" },
    };
    s.didChange("file:///a.zig", 2, &changes, "WHOLE TEXT");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    const arr = sent.items[0].params().object.get("contentChanges").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expect(arr.items[0].object.get("range") == null);
    try testing.expectEqualStrings("WHOLE TEXT", arr.items[0].object.get("text").?.string);
}

test "session: didOpen escapes control characters and multibyte text survives" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();
    s.didOpen("file:///a.zig", "zig", 1, "a\t\"b\"\n\u{1F600}\x01");
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    const td = sent.items[0].params().object.get("textDocument").?.object;
    try testing.expectEqualStrings("a\t\"b\"\n\u{1F600}\x01", td.get("text").?.string);
    try testing.expectEqualStrings("zig", td.get("languageId").?.string);
}

test "session: a stale response still carries the revision it was built for" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();

    const req = s.sendRequest(.hover, "textDocument/hover", "{}", .{
        .id = 0,
        .kind = .hover,
        .tab_id = 42,
        .revision = 11,
    }).?;
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.print(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":1}}}}", .{req.id});
    try feedJson(&s, alloc, body.items);
    try testing.expectEqual(@as(usize, 1), rec.responses.items.len);
    try testing.expectEqual(@as(u64, 11), rec.responses.items[0].req.revision);
    try testing.expectEqual(@as(u64, 42), rec.responses.items[0].req.tab_id);
    try testing.expectEqual(session.Kind.hover, rec.responses.items[0].req.kind);
}

test "session: cancelling suppresses the answer and sends $/cancelRequest" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();

    const a = s.sendRequest(.completion, "textDocument/completion", "{}", .{ .id = 0, .kind = .completion, .tab_id = 1, .revision = 1 }).?;
    try testing.expect(s.hasPending(.completion, 1));
    s.cancelKind(.completion, 1);
    try testing.expect(!s.hasPending(.completion, 1));

    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
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
    defer body.deinit(alloc);
    try body.print(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{a.id});
    try feedJson(&s, alloc, body.items);
    try testing.expectEqual(@as(usize, 0), rec.responses.items.len);
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "session: forgetTab drops that tab's requests only" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    _ = s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover, .tab_id = 1 });
    _ = s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover, .tab_id = 2 });
    s.forgetTab(1);
    try testing.expect(!s.hasPending(.hover, 1));
    try testing.expect(s.hasPending(.hover, 2));
}

test "session: server-to-client requests are always answered" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();

    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":88,"method":"window/workDoneProgress/create","params":{"token":"t"}}
    );
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":89,"method":"workspace/configuration","params":{"items":[{"section":"a"},{"section":"b"}]}}
    );
    // Not `workspace/applyEdit` any more: that one IS implemented now
    // (it is how a command-carrying code action does its work).
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":90,"method":"workspace/codeLens/refresh","params":{}}
    );
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
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
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();

    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","id":"i_haz_configuration","method":"workspace/configuration","params":{"items":[{"section":"zls"}]}}
    );
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try testing.expectEqual(@as(usize, 1), sent.items.len);
    const reply = sent.items[0].parsed.value.object;
    try testing.expectEqualStrings("i_haz_configuration", reply.get("id").?.string);
    try testing.expectEqual(@as(usize, 1), reply.get("result").?.array.items.len);
}

test "session: notifications reach the handler" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.zig","diagnostics":[]}}
    );
    try testing.expectEqual(@as(usize, 1), rec.notifications.items.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", rec.notifications.items[0]);
}

test "session: shutdown is followed by exit and the dead state" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.out.clearRetainingCapacity();
    s.stop();
    var sent: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &sent);
    try drain(alloc, &s, &sent);
    try testing.expectEqualStrings("shutdown", sent.items[0].method());
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.print(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{sent.items[0].id().?});
    try feedJson(&s, alloc, body.items);
    try testing.expectEqual(session.State.dead, s.state);
    var after: std.ArrayList(Sent) = .empty;
    defer freeSent(alloc, &after);
    try drain(alloc, &s, &after);
    try testing.expectEqualStrings("exit", after.items[0].method());
}

test "session: lost framing kills the session rather than desynchronising" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.feed("garbage without a header\r\n\r\nmore");
    try testing.expectEqual(session.State.dead, s.state);
    try testing.expect(std.mem.indexOf(u8, s.errText(), "framing") != null);
}

test "session: an unparsable message is skipped, framing is kept" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    try feedJson(&s, alloc, "{not json");
    try testing.expectEqual(session.State.ready, s.state);
    try feedJson(&s, alloc,
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{}}
    );
    try testing.expectEqual(@as(usize, 1), rec.notifications.items.len);
}

test "session: requests are refused once the session is dead" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    s.markDead();
    try testing.expect(s.sendRequest(.hover, "textDocument/hover", "{}", .{ .id = 0, .kind = .hover }) == null);
}

test "session: a dead server leaves no request in flight" {
    // The outline panel asks "is my documentSymbol still out there?"
    // instead of keeping a pending flag, so a server that dies with one
    // outstanding must not look like it is still thinking — that is
    // what once left a tab never asking for symbols again.
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    _ = s.sendRequest(.document_symbol, "textDocument/documentSymbol", "{}", .{
        .id = 0,
        .kind = .document_symbol,
        .tab_id = 4,
    });
    try testing.expect(s.hasPending(.document_symbol, 4));
    try testing.expect(!s.hasPending(.document_symbol, 5));
    s.markDead();
    try testing.expect(!s.hasPending(.document_symbol, 4));
}

test "session: a closing tab leaves no request in flight" {
    const alloc = testing.allocator;
    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Session.init(alloc, rec.handler());
    defer s.deinit();
    try readySession(alloc, &s);
    _ = s.sendRequest(.document_symbol, "textDocument/documentSymbol", "{}", .{
        .id = 0,
        .kind = .document_symbol,
        .tab_id = 6,
    });
    try testing.expect(s.hasPending(.document_symbol, 6));
    s.forgetTab(6);
    try testing.expect(!s.hasPending(.document_symbol, 6));
}

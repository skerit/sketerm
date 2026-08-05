//! smoke-editor's language-server stage: a REAL child process
//! (`sketerm-lsp-stub`) driven over real non-blocking pipes through the
//! production `Session`, `DocSync` and position mapper.
//!
//! What this proves that the unit tests cannot: the spawn path, the
//! framing across arbitrary pipe chunking, and — most importantly —
//! that the client's incremental `didChange` ranges are correct, because
//! the stub maintains its OWN copy of the document from those ranges
//! and publishes diagnostics against it. If a range is off by one
//! UTF-16 unit, the stub's copy diverges and the diagnostic offsets the
//! client maps back stop matching the local document.
//!
//! The whole stage runs twice, once per `positionEncoding`, over a
//! document deliberately full of astral-plane characters.

const std = @import("std");
const c = @import("c.zig").c;
const Document = @import("editor/document.zig").Document;
const tr = @import("editor/transaction.zig");
const rpc = @import("lsp/rpc.zig");
const session = @import("lsp/session.zig");
const pos = @import("lsp/position.zig");
const proc = @import("lsp/proc.zig");
const diagnostics = @import("lsp/diagnostics.zig");
const docsync = @import("lsp/docsync.zig");
const servers = @import("lsp/servers.zig");
const inlay = @import("lsp/inlay.zig");
const semantic = @import("lsp/semantic.zig");
const syntax = @import("editor/syntax.zig");
const theme = @import("editor/theme.zig");

/// The client's own LSP-modifier-name -> render-bit map, duplicated
/// here on purpose: editorlsp.zig is GTK and cannot be imported into a
/// headless rig, and hard-coding the BITS instead would test nothing.
fn modBit(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "readonly")) return syntax.MOD_READONLY;
    if (std.mem.eql(u8, name, "deprecated")) return syntax.MOD_DEPRECATED;
    if (std.mem.eql(u8, name, "defaultLibrary")) return syntax.MOD_DEFAULT_LIBRARY;
    return 0;
}

const URI = "file:///smoke/main.zig";

/// A document whose lines mix ASCII, BMP multibyte and astral-plane
/// characters, so every position conversion is exercised.
const SRC =
    "fn alpha() void {\n" ++
    "    const emoji = \"\u{1F600}\u{1F680}\";  \n" ++
    "    const greek = \"\u{03b1}\u{03b2}\u{03b3}\";\n" ++
    "    call(BAD, emoji);\n" ++
    "}\n" ++
    "fn beta() void { MEH; }\n" ++
    "var SEMRO = SEMDEP;\n";

const Harness = struct {
    alloc: std.mem.Allocator,
    child: proc.Child,
    sess: session.Session,
    doc: Document,
    sync: docsync.DocSync,
    diags: diagnostics.Store,
    /// Set by the notification handler.
    published: usize = 0,
    /// Last response seen, so a step can wait for its own answer.
    last_kind: ?session.Kind = null,
    last_result: []u8 = &.{},
    last_error: bool = false,

    fn handler(self: *Harness) session.Handler {
        return .{
            .ctx = self,
            .on_response = onResponse,
            .on_notification = onNotification,
            .on_state = onState,
            .on_apply_edit = onApplyEdit,
        };
    }

    /// The harness applies nothing (it drives the protocol, not the
    /// editor); answering `false` is the honest reply and still keeps
    /// the server from blocking.
    fn onApplyEdit(_: *anyopaque, _: std.json.Value) bool {
        return false;
    }

    fn onState(_: *anyopaque, _: session.State) void {}

    fn onResponse(ctx: *anyopaque, req: session.Request, env: rpc.Envelope) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        if (self.last_result.len > 0) self.alloc.free(self.last_result);
        self.last_result = &.{};
        self.last_error = env.has_error;
        var w: std.Io.Writer.Allocating = .init(self.alloc);
        defer w.deinit();
        std.json.Stringify.value(env.result, .{}, &w.writer) catch return;
        self.last_result = self.alloc.dupe(u8, w.written()) catch &.{};
        self.last_kind = req.kind;
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const arr = switch (obj.get("diagnostics") orelse std.json.Value.null) {
            .array => |a| a,
            else => return,
        };
        var list: std.ArrayList(diagnostics.Diagnostic) = .empty;
        defer list.deinit(self.alloc);
        for (arr.items) |d| {
            if (d != .object) continue;
            const r = pos.parseRange(d.object.get("range") orelse .null);
            const offs = pos.rangeToOffsets(&self.doc.rope, r, self.sess.caps.encoding);
            const msg = switch (d.object.get("message") orelse std.json.Value.null) {
                .string => |s| s,
                else => "",
            };
            const sev = switch (d.object.get("severity") orelse std.json.Value.null) {
                .integer => |i| diagnostics.Severity.fromInt(i),
                else => .err,
            };
            list.append(self.alloc, .{
                .start = offs.start,
                .end = offs.end,
                .severity = sev,
                .message = @constCast(msg),
                .source = @constCast(@as([]const u8, "stub")),
            }) catch return;
        }
        self.diags.replace(self.doc.revision, list.items) catch return;
        self.published += 1;
    }

    fn pump(self: *Harness) void {
        // Writes first: the server cannot answer what it has not read.
        var off: usize = 0;
        while (off < self.sess.out.items.len) {
            const rest = self.sess.out.items[off..];
            const n = c.write(self.child.stdin, rest.ptr, rest.len);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const e = std.posix.errno(@as(isize, @intCast(n)));
            if (e == .AGAIN or e == .INTR) {
                _ = c.usleep(500);
                continue;
            }
            break;
        }
        self.sess.out.clearRetainingCapacity();
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = c.read(self.child.stdout, &buf, buf.len);
            if (n > 0) {
                self.sess.feed(buf[0..@intCast(n)]);
                continue;
            }
            break;
        }
    }

    /// Pump until `cond` or the deadline. Returns false on timeout.
    fn waitFor(self: *Harness, ctx: anytype, cond: *const fn (@TypeOf(ctx)) bool, ms: usize) bool {
        var spent: usize = 0;
        while (spent < ms) : (spent += 1) {
            self.pump();
            if (cond(ctx)) return true;
            _ = c.usleep(1000);
        }
        self.pump();
        return cond(ctx);
    }

    fn readyCond(self: *Harness) bool {
        return self.sess.state == .ready;
    }

    fn publishedCond(self: *Harness) bool {
        return self.published > 0;
    }

    fn answeredCond(self: *Harness) bool {
        return self.last_kind != null;
    }

    fn request(self: *Harness, kind: session.Kind, method: []const u8, params: []const u8) bool {
        if (self.last_result.len > 0) {
            self.alloc.free(self.last_result);
            self.last_result = &.{};
        }
        self.last_kind = null;
        _ = self.sess.sendRequest(kind, method, params, .{
            .id = 0,
            .kind = kind,
            .tab_id = 1,
            .revision = self.doc.revision,
        }) orelse return false;
        return self.waitFor(self, answeredCond, 4000);
    }

    fn deinit(self: *Harness) void {
        self.sess.stop();
        self.pump();
        if (self.last_result.len > 0) self.alloc.free(self.last_result);
        self.child.terminate();
        self.child.killHard();
        self.child.closePipes();
        _ = self.child.reap();
        self.sess.deinit();
        self.sync.deinit();
        self.diags.deinit();
        self.doc.deinit();
    }
};

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("smoke-editor: FAIL — " ++ fmt ++ "\n", args);
    return 2;
}

/// Byte offset of `needle` in the document (first occurrence).
fn offsetOf(doc: *const Document, alloc: std.mem.Allocator, needle: []const u8) ?usize {
    const text = doc.textAlloc(alloc) catch return null;
    defer alloc.free(text);
    return std.mem.indexOf(u8, text, needle);
}

fn docPos(h: *Harness, offset: usize, extra: []const u8, out: *std.ArrayList(u8)) !void {
    const p = pos.offsetToPosition(&h.doc.rope, offset, h.sess.caps.encoding);
    out.clearRetainingCapacity();
    try out.print(
        h.alloc,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}{s}}}",
        .{ URI, p.line, p.character, extra },
    );
}

pub fn stage(alloc: std.mem.Allocator) !?u8 {
    for ([_]bool{ false, true }) |utf8| {
        if (try runOnce(alloc, utf8)) |code| return code;
    }
    return rangeOnlyStage(alloc);
}

/// A server offering `semanticTokens/range` and NOT `full` used to be
/// treated as offering nothing. One extra child proves the whole path:
/// the capability is seen, the request is answered, and the answer
/// contains ONLY tokens inside the window asked for.
fn rangeOnlyStage(alloc: std.mem.Allocator) !?u8 {
    const exe = "zig-out/bin/sketerm-lsp-stub";
    if (c.access(exe, c.X_OK) != 0) return null;
    var h = Harness{
        .alloc = alloc,
        .child = try proc.spawn(alloc, exe, &.{"--range-only"}, "."),
        .sess = undefined,
        .doc = try Document.initFromBytes(alloc, SRC),
        .sync = docsync.DocSync.init(alloc),
        .diags = diagnostics.Store.init(alloc),
    };
    h.sess = session.Session.init(alloc, h.handler());
    defer h.deinit();
    h.sess.start("file:///smoke", c.getpid(), "");
    if (!h.waitFor(&h, Harness.readyCond, 4000)) return fail("range-only stub never reached ready", .{});
    if (h.sess.caps.semantic_tokens) return fail("range-only stub advertised `full`", .{});
    if (!h.sess.caps.semantic_tokens_range) return fail("the `range` provider was not recognised", .{});
    if (h.sess.caps.token_types.types.items.len == 0)
        return fail("a range-only provider's legend was thrown away", .{});

    try h.sync.setUri(URI);
    h.sync.open = true;
    h.sync.version = 1;
    {
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        h.sess.didOpen(URI, "zig", 1, text);
    }

    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(alloc);
    // Lines 0..2 only — the document is six lines long.
    try params.print(
        alloc,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":2,\"character\":0}}}}}}",
        .{URI},
    );
    if (!h.request(.semantic_tokens_range, "textDocument/semanticTokens/range", params.items))
        return fail("semanticTokens/range timed out", .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
    defer parsed.deinit();
    var data = semantic.Data.init(alloc);
    defer data.deinit();
    if (!data.absorbFull(parsed.value)) return fail("could not absorb the range token array", .{});
    const toks = try data.decode(alloc);
    defer alloc.free(toks);
    if (toks.len == 0) return fail("the range answer carried no tokens", .{});
    for (toks) |t| {
        if (t.line >= 2) return fail("a range answer carried a token on line {d}, outside 0..2", .{t.line});
    }
    std.debug.print("smoke-editor: PASS lsp/range-only ({d} tokens, all inside the window)\n", .{toks.len});
    return null;
}

fn runOnce(alloc: std.mem.Allocator, utf8: bool) !?u8 {
    const exe = "zig-out/bin/sketerm-lsp-stub";
    if (c.access(exe, c.X_OK) != 0) {
        std.debug.print("smoke-editor: NOTE — {s} missing; LSP stage skipped\n", .{exe});
        return null;
    }
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    if (utf8) try args.append(alloc, "--utf8");

    var h = Harness{
        .alloc = alloc,
        .child = try proc.spawn(alloc, exe, args.items, "."),
        .sess = undefined,
        .doc = try Document.initFromBytes(alloc, SRC),
        .sync = docsync.DocSync.init(alloc),
        .diags = diagnostics.Store.init(alloc),
    };
    h.sess = session.Session.init(alloc, h.handler());
    defer h.deinit();

    h.sess.start("file:///smoke", c.getpid(), "");
    if (!h.waitFor(&h, Harness.readyCond, 4000)) return fail("stub server never reached ready", .{});
    const want_enc: pos.Encoding = if (utf8) .utf8 else .utf16;
    if (h.sess.caps.encoding != want_enc)
        return fail("negotiated encoding {s}, wanted {s}", .{ @tagName(h.sess.caps.encoding), @tagName(want_enc) });
    if (h.sess.caps.sync != .incremental) return fail("stub did not ask for incremental sync", .{});

    // ---- didOpen + diagnostics --------------------------------------
    try h.sync.setUri(URI);
    h.sync.language_id = "zig";
    h.sync.open = true;
    h.sync.version = 1;
    {
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        h.sess.didOpen(URI, "zig", 1, text);
    }
    if (!h.waitFor(&h, Harness.publishedCond, 4000)) return fail("no diagnostics published", .{});
    {
        const cnt = h.diags.counts();
        if (cnt.errors != 1 or cnt.warnings != 1)
            return fail("expected 1 error + 1 warning, got {d}/{d}", .{ cnt.errors, cnt.warnings });
        const bad = offsetOf(&h.doc, alloc, "BAD") orelse return fail("test document lost its marker", .{});
        const d = h.diags.at(bad) orelse return fail("no diagnostic at the BAD offset {d}", .{bad});
        if (d.start != bad) return fail("diagnostic at {d}, expected {d}", .{ d.start, bad });
        if (d.severity != .err) return fail("BAD is not an error", .{});
    }

    // ---- incremental didChange --------------------------------------
    //
    // Inserting BEFORE the emoji line shifts every later position; the
    // stub rebuilds its copy from the ranges we send, so the next
    // publish only lands correctly if those ranges were right.
    {
        const insert_at = offsetOf(&h.doc, alloc, "    const emoji") orelse
            return fail("marker line missing", .{});
        var tx = tr.Transaction.init(h.doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, insert_at, "    // \u{1F604} inserted\n");
        // Capture against the PRE-edit document, exactly like the
        // editor's document observer does.
        h.sync.noteEdits(&h.doc, tx.edits.items, h.sess.caps.encoding);
        _ = try h.doc.applyTransaction(&tx);
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        h.published = 0;
        h.sync.flush(&h.sess, text);
    }
    if (!h.waitFor(&h, Harness.publishedCond, 4000)) return fail("no diagnostics after didChange", .{});
    {
        const bad = offsetOf(&h.doc, alloc, "BAD") orelse return fail("marker gone", .{});
        const d = h.diags.at(bad) orelse return fail("diagnostic did not follow the edit (want {d})", .{bad});
        if (d.start != bad)
            return fail("incremental sync desynchronised: diagnostic at {d}, BAD at {d}", .{ d.start, bad });
    }

    // A second, MULTI-edit transaction: the queue must reproduce the
    // document's own back-to-front application.
    {
        const emoji_at = offsetOf(&h.doc, alloc, "\u{1F680}") orelse return fail("rocket gone", .{});
        const greek_at = offsetOf(&h.doc, alloc, "\u{03b3}") orelse return fail("gamma gone", .{});
        var tx = tr.Transaction.init(h.doc.revision);
        defer tx.deinit(alloc);
        try tx.addReplace(alloc, emoji_at, "\u{1F680}".len, "\u{1F525}");
        try tx.addInsert(alloc, greek_at, "\u{03b4}");
        h.sync.noteEdits(&h.doc, tx.edits.items, h.sess.caps.encoding);
        _ = try h.doc.applyTransaction(&tx);
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        h.published = 0;
        h.sync.flush(&h.sess, text);
    }
    if (!h.waitFor(&h, Harness.publishedCond, 4000)) return fail("no diagnostics after multi-edit", .{});
    {
        const meh = offsetOf(&h.doc, alloc, "MEH") orelse return fail("MEH gone", .{});
        const d = h.diags.at(meh) orelse return fail("warning did not follow the multi-edit", .{});
        if (d.start != meh) return fail("multi-edit desync: warning at {d}, MEH at {d}", .{ d.start, meh });
        if (d.severity != .warning) return fail("MEH is not a warning", .{});
    }

    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(alloc);

    // ---- hover: the stub echoes the word it resolved from OUR position
    {
        const at = (offsetOf(&h.doc, alloc, "emoji") orelse return fail("no emoji ident", .{})) + 2;
        try docPos(&h, at, "", &params);
        if (!h.request(.hover, "textDocument/hover", params.items)) return fail("hover timed out", .{});
        if (std.mem.indexOf(u8, h.last_result, "word='emoji'") == null)
            return fail("hover resolved the wrong word: {s}", .{h.last_result});
    }

    // ---- go to definition -------------------------------------------
    {
        const at = (offsetOf(&h.doc, alloc, "call(BAD") orelse return fail("no call", .{})) + 1;
        try docPos(&h, at, "", &params);
        if (!h.request(.definition, "textDocument/definition", params.items)) return fail("definition timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len != 1)
            return fail("definition returned {s}", .{h.last_result});
        const r = pos.parseRange(parsed.value.array.items[0].object.get("range").?);
        const offs = pos.rangeToOffsets(&h.doc.rope, r, h.sess.caps.encoding);
        const want = offsetOf(&h.doc, alloc, "call").?;
        if (offs.start != want) return fail("definition landed at {d}, expected {d}", .{ offs.start, want });
    }

    // ---- references: several hits ------------------------------------
    {
        const at = (offsetOf(&h.doc, alloc, "emoji") orelse unreachable) + 1;
        try docPos(&h, at, ",\"context\":{\"includeDeclaration\":true}", &params);
        if (!h.request(.references, "textDocument/references", params.items)) return fail("references timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len < 2)
            return fail("references returned {s}", .{h.last_result});
    }

    // ---- document symbols --------------------------------------------
    {
        params.clearRetainingCapacity();
        try params.print(alloc, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{URI});
        if (!h.request(.document_symbol, "textDocument/documentSymbol", params.items))
            return fail("documentSymbol timed out", .{});
        if (std.mem.indexOf(u8, h.last_result, "\"alpha\"") == null or
            std.mem.indexOf(u8, h.last_result, "\"beta\"") == null)
            return fail("documentSymbol missed a function: {s}", .{h.last_result});
    }

    // ---- completion + lazy resolve -----------------------------------
    {
        const at = offsetOf(&h.doc, alloc, "call(") orelse unreachable;
        try docPos(&h, at + 5, ",\"context\":{\"triggerKind\":1}", &params);
        if (!h.request(.completion, "textDocument/completion", params.items)) return fail("completion timed out", .{});
        if (std.mem.indexOf(u8, h.last_result, "stubAlpha") == null)
            return fail("completion missing items: {s}", .{h.last_result});
        // The item goes back verbatim for resolve, which is how the
        // real client fills in documentation lazily.
        if (!h.request(
            .completion_resolve,
            "completionItem/resolve",
            "{\"label\":\"stubAlpha\",\"kind\":3}",
        )) return fail("resolve timed out", .{});
        if (std.mem.indexOf(u8, h.last_result, "stub docs for stubAlpha") == null)
            return fail("resolve returned no documentation: {s}", .{h.last_result});
    }

    // ---- rename: a multi-edit workspace edit applied as ONE undo unit
    {
        const at = (offsetOf(&h.doc, alloc, "emoji") orelse unreachable) + 1;
        try docPos(&h, at, ",\"newName\":\"picto\"", &params);
        if (!h.request(.rename, "textDocument/rename", params.items)) return fail("rename timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        const changes = parsed.value.object.get("changes").?.object.get(URI).?.array;
        if (changes.items.len < 2) return fail("rename touched {d} sites", .{changes.items.len});
        const undo_before = h.doc.undo_stack.items.len;
        if (!applyTextEdits(alloc, &h, changes.items)) return fail("could not apply the rename edits", .{});
        if (h.doc.undo_stack.items.len != undo_before + 1)
            return fail("rename produced {d} undo units, expected 1", .{h.doc.undo_stack.items.len - undo_before});
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "emoji") != null) return fail("rename left an old name behind", .{});
        if (std.mem.count(u8, text, "picto") < 2) return fail("rename did not reach every site", .{});
        // One undo puts the whole rename back.
        _ = try h.doc.undo();
        const back = try h.doc.textAlloc(alloc);
        defer alloc.free(back);
        if (std.mem.indexOf(u8, back, "picto") != null) return fail("one undo did not revert the whole rename", .{});
        _ = try h.doc.redo();
    }

    // ---- formatting: several edits, one undo unit ---------------------
    {
        params.clearRetainingCapacity();
        try params.print(
            alloc,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}",
            .{URI},
        );
        // The server formats ITS copy, which only matches ours if every
        // change we sent was right; resync it first.
        {
            const text = try h.doc.textAlloc(alloc);
            defer alloc.free(text);
            h.sync.version += 1;
            h.sess.didChange(URI, h.sync.version, &.{}, text);
            h.pump();
        }
        if (!h.request(.formatting, "textDocument/formatting", params.items)) return fail("formatting timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len == 0)
            return fail("formatting produced no edits: {s}", .{h.last_result});
        const undo_before = h.doc.undo_stack.items.len;
        if (!applyTextEdits(alloc, &h, parsed.value.array.items)) return fail("could not apply format edits", .{});
        if (h.doc.undo_stack.items.len != undo_before + 1)
            return fail("formatting produced more than one undo unit", .{});
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, " \n") != null)
            return fail("formatting left trailing whitespace behind", .{});
    }

    // ---- signature help: the ACTIVE parameter follows the caret -------
    {
        const call_at = offsetOf(&h.doc, alloc, "call(") orelse return fail("call site gone", .{});
        // Inside the first argument…
        try docPos(&h, call_at + 5, "", &params);
        if (!h.request(.signature_help, "textDocument/signatureHelp", params.items))
            return fail("signatureHelp timed out", .{});
        var first = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer first.deinit();
        if (first.value != .object) return fail("signatureHelp answered {s}", .{h.last_result});
        if (first.value.object.get("activeParameter").?.integer != 0)
            return fail("expected parameter 0 inside the first argument", .{});
        // …and past the comma (`call(BAD, emoji)` — offset +10 is
        // inside the second argument).
        try docPos(&h, call_at + 10, "", &params);
        if (!h.request(.signature_help, "textDocument/signatureHelp", params.items))
            return fail("second signatureHelp timed out", .{});
        var second = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer second.deinit();
        if (second.value.object.get("activeParameter").?.integer != 1)
            return fail("the active parameter did not follow the caret past the comma", .{});
    }

    // ---- code actions: the quick fix carries a real edit --------------
    {
        const bad = offsetOf(&h.doc, alloc, "BAD") orelse return fail("marker gone", .{});
        const s = pos.offsetToPosition(&h.doc.rope, bad, h.sess.caps.encoding);
        const e = pos.offsetToPosition(&h.doc.rope, bad + 3, h.sess.caps.encoding);
        params.clearRetainingCapacity();
        try params.print(
            alloc,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"context\":{{\"diagnostics\":[]}}}}",
            .{ URI, s.line, s.character, e.line, e.character },
        );
        if (!h.request(.code_action, "textDocument/codeAction", params.items))
            return fail("codeAction timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len < 3)
            return fail("expected three code actions, got {s}", .{h.last_result});
        // The quickfix's edit must land exactly on BAD.
        const fix = parsed.value.array.items[0].object;
        const edits = fix.get("edit").?.object.get("changes").?.object.get(URI).?.array;
        const r = pos.rangeToOffsets(
            &h.doc.rope,
            pos.parseRange(edits.items[0].object.get("range").?),
            h.sess.caps.encoding,
        );
        if (r.start != bad or r.end != bad + 3)
            return fail("the quick fix targets {d}..{d}, BAD is at {d}", .{ r.start, r.end, bad });
        // A command-carrying one and a resolve-only one are both there.
        if (parsed.value.array.items[1].object.get("command") == null)
            return fail("no command-carrying action offered", .{});
        const lazy = parsed.value.array.items[2];
        if (lazy.object.get("edit") != null) return fail("the lazy action should have no edit yet", .{});
        var raw: std.Io.Writer.Allocating = .init(alloc);
        defer raw.deinit();
        try std.json.Stringify.value(lazy, .{}, &raw.writer);
        if (!h.request(.code_action_resolve, "codeAction/resolve", raw.written()))
            return fail("codeAction/resolve timed out", .{});
        var resolved = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer resolved.deinit();
        if (resolved.value.object.get("edit") == null)
            return fail("resolve did not fill the edit in: {s}", .{h.last_result});
    }

    // ---- inlay hints: the RANGE is honoured ---------------------------
    {
        params.clearRetainingCapacity();
        try params.print(
            alloc,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":2,\"character\":0}}}}}}",
            .{URI},
        );
        if (!h.request(.inlay_hint, "textDocument/inlayHint", params.items))
            return fail("inlayHint timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        var set = inlay.Set.init(alloc);
        defer set.deinit();
        try set.absorb(parsed.value, &h.doc.rope, h.sess.caps.encoding, h.doc.revision, 0, 2);
        if (set.items.items.len != 3)
            return fail("expected 3 hints for lines 0..2, got {d}", .{set.items.items.len});
        // Every hint sits at a real newline boundary — proof that the
        // utf-16 positions on the emoji line were mapped, not counted.
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        for (set.items.items) |hint| {
            if (hint.offset >= text.len or text[hint.offset] != '\n')
                return fail("hint at {d} is not at a line end", .{hint.offset});
        }
        if (!set.covers(1, 2)) return fail("the hint set does not claim its own window", .{});
        if (set.covers(0, 9)) return fail("the hint set claims lines it never asked for", .{});

        // ---- inlayHint/resolve ---------------------------------------
        //
        // The stub answers with a tooltip quoting the `data` field it
        // put on the hint, which ONLY the server's own object carries —
        // so a client that reconstructs a hint instead of keeping the
        // raw JSON resolves to `data=0` and this fails.
        if (!h.sess.caps.inlay_hint_resolve) return fail("stub did not offer inlayHint/resolve", .{});
        if (set.items.items[0].raw.len == 0) return fail("the hint kept no raw JSON to resolve with", .{});
        if (set.items.items[0].tooltip.len != 0) return fail("the hint arrived with a tooltip already", .{});
        if (!h.request(.inlay_hint_resolve, "inlayHint/resolve", set.items.items[0].raw))
            return fail("inlayHint/resolve timed out", .{});
        var rparsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer rparsed.deinit();
        if (!set.absorbResolved(0, rparsed.value)) return fail("the resolved hint carried no tooltip", .{});
        if (std.mem.indexOf(u8, set.items.items[0].tooltip, "data=100") == null)
            return fail("resolve did not round-trip the server's own data field: '{s}'", .{set.items.items[0].tooltip});
        // The hint's own offset is unchanged — resolve decorates, it
        // does not move anything.
        if (set.indexAtOffset(set.items.items[0].offset) != 0)
            return fail("the resolved hint is no longer findable at its anchor", .{});
    }

    // ---- semantic tokens: full, then a delta that splices -------------
    {
        params.clearRetainingCapacity();
        try params.print(alloc, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{URI});
        if (!h.request(.semantic_tokens_full, "textDocument/semanticTokens/full", params.items))
            return fail("semanticTokens/full timed out", .{});
        var data = semantic.Data.init(alloc);
        defer data.deinit();
        {
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
            defer parsed.deinit();
            if (!data.absorbFull(parsed.value)) return fail("could not absorb the token array", .{});
        }
        if (data.result_id.len == 0) return fail("no resultId, so no delta is possible", .{});
        const full_toks = try data.decode(alloc);
        defer alloc.free(full_toks);
        if (full_toks.len < 5) return fail("only {d} semantic tokens", .{full_toks.len});
        // `fn` is a keyword (index 2) and the name after it a function
        // (index 0) — the stub's own classification, so a decode bug
        // shows up as the wrong index rather than as nothing.
        var saw_fn_kw = false;
        var saw_fn_name = false;
        for (full_toks) |t| {
            if (t.type_index == 2) saw_fn_kw = true;
            if (t.type_index == 0) saw_fn_name = true;
        }
        if (!saw_fn_kw or !saw_fn_name) return fail("token types did not decode", .{});

        // Token MODIFIERS: the stub marks SEMRO readonly (legend bit 1)
        // and SEMDEP deprecated (bit 2). Fold them by NAME through the
        // legend, exactly as the client does, and check the render-side
        // bits that come out — a legend-order assumption would pass
        // here and mis-colour against every real server.
        {
            const ro_off = offsetOf(&h.doc, alloc, "SEMRO") orelse
                return fail("test document lost SEMRO", .{});
            const dep_off = offsetOf(&h.doc, alloc, "SEMDEP") orelse
                return fail("test document lost SEMDEP", .{});
            var saw_ro = false;
            var saw_dep = false;
            for (full_toks) |t| {
                const toff = pos.positionToOffset(
                    &h.doc.rope,
                    .{ .line = t.line, .character = t.start_char },
                    h.sess.caps.encoding,
                );
                const bits = h.sess.caps.token_types.foldMods(t.modifiers, u8, &modBit);
                if (toff == ro_off) {
                    if (bits != syntax.MOD_READONLY)
                        return fail("SEMRO folded to modifier bits 0x{x}, wanted readonly", .{bits});
                    saw_ro = true;
                }
                if (toff == dep_off) {
                    if (bits != syntax.MOD_DEPRECATED)
                        return fail("SEMDEP folded to modifier bits 0x{x}, wanted deprecated", .{bits});
                    saw_dep = true;
                }
                // Nothing else may pick up a modifier by accident.
                if (toff != ro_off and toff != dep_off and bits != 0)
                    return fail("an unmarked token carried modifier bits 0x{x}", .{bits});
            }
            if (!saw_ro or !saw_dep) return fail("the modified tokens never arrived", .{});
            // …and the theme turns those bits into a different style.
            const plain = theme.dark.style(.property);
            const ro = theme.dark.style(syntax.withMods(.property, syntax.MOD_READONLY));
            if (std.mem.eql(u8, &std.mem.toBytes(plain.rgba), &std.mem.toBytes(ro.rgba)))
                return fail("readonly resolved to the same colour as plain", .{});
            if (!theme.dark.style(syntax.withMods(.function, syntax.MOD_DEPRECATED)).strike)
                return fail("deprecated did not resolve to a strikethrough", .{});
        }
        // Positions must land on identifier starts in OUR copy.
        const first = full_toks[0];
        const off = pos.positionToOffset(
            &h.doc.rope,
            .{ .line = first.line, .character = first.start_char },
            h.sess.caps.encoding,
        );
        const text = try h.doc.textAlloc(alloc);
        defer alloc.free(text);
        if (off >= text.len or !isWordyByte(text[off]))
            return fail("the first token does not start on an identifier (offset {d})", .{off});

        const before_id = try alloc.dupe(u8, data.result_id);
        defer alloc.free(before_id);
        params.clearRetainingCapacity();
        try params.print(
            alloc,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"previousResultId\":\"{s}\"}}",
            .{ URI, before_id },
        );
        if (!h.request(.semantic_tokens_delta, "textDocument/semanticTokens/full/delta", params.items))
            return fail("semanticTokens delta timed out", .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, h.last_result, .{});
        defer parsed.deinit();
        if (!data.absorbDelta(parsed.value)) return fail("could not apply the token delta", .{});
        if (std.mem.eql(u8, data.result_id, before_id)) return fail("the delta did not move the resultId", .{});
        const after = try data.decode(alloc);
        defer alloc.free(after);
        if (after.len != full_toks.len)
            return fail("the delta changed the token count ({d} -> {d})", .{ full_toks.len, after.len });
        for (after, full_toks) |a, b| {
            if (a.line != b.line or a.start_char != b.start_char or a.type_index != b.type_index)
                return fail("the delta produced a different token set", .{});
        }
    }

    std.debug.print(
        "smoke-editor: PASS lsp/{s} (diagnostics, incremental sync, hover, definition, references, symbols, completion+resolve, rename, formatting, signature help, code actions+resolve, inlay hints, semantic tokens+delta)\n",
        .{@tagName(want_enc)},
    );
    return null;
}

fn isWordyByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch >= 0x80;
}

/// The same fold the GUI does: LSP TextEdits (original coordinates,
/// non-overlapping) become ONE transaction, hence one undo unit.
fn applyTextEdits(alloc: std.mem.Allocator, h: *Harness, edits: []const std.json.Value) bool {
    const Pending = struct { start: usize, end: usize, text: []const u8 };
    var list: std.ArrayList(Pending) = .empty;
    defer list.deinit(alloc);
    for (edits) |e| {
        if (e != .object) continue;
        const r = pos.parseRange(e.object.get("range") orelse .null);
        const offs = pos.rangeToOffsets(&h.doc.rope, r, h.sess.caps.encoding);
        const text = switch (e.object.get("newText") orelse std.json.Value.null) {
            .string => |s| s,
            else => "",
        };
        list.append(alloc, .{ .start = offs.start, .end = offs.end, .text = text }) catch return false;
    }
    std.mem.sort(Pending, list.items, {}, struct {
        fn less(_: void, a: Pending, b: Pending) bool {
            return a.start < b.start;
        }
    }.less);
    var tx = tr.Transaction.init(h.doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (list.items, 0..) |p, i| {
        if (i > 0 and p.start < prev_end) continue;
        tx.addReplace(alloc, p.start, p.end - p.start, p.text) catch return false;
        prev_end = p.end;
    }
    _ = h.doc.applyTransaction(&tx) catch return false;
    return true;
}

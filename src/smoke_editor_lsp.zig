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

const URI = "file:///smoke/main.zig";

/// A document whose lines mix ASCII, BMP multibyte and astral-plane
/// characters, so every position conversion is exercised.
const SRC =
    "fn alpha() void {\n" ++
    "    const emoji = \"\u{1F600}\u{1F680}\";  \n" ++
    "    const greek = \"\u{03b1}\u{03b2}\u{03b3}\";\n" ++
    "    call(BAD, emoji);\n" ++
    "}\n" ++
    "fn beta() void { MEH; }\n";

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
        return .{ .ctx = self, .on_response = onResponse, .on_notification = onNotification, .on_state = onState };
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

    std.debug.print(
        "smoke-editor: PASS lsp/{s} (diagnostics, incremental sync, hover, definition, references, symbols, completion+resolve, rename, formatting)\n",
        .{@tagName(want_enc)},
    );
    return null;
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

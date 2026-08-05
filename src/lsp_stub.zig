//! `sketerm-lsp-stub` — a real, scripted language server process used
//! by the tests. It speaks the base protocol over stdio exactly like
//! zls or clangd, so the transport, framing, process lifetime and
//! position mapping are all exercised end to end without depending on
//! any language server being installed on the build host.
//!
//! Its "language" is trivial and deterministic:
//!
//!   * every occurrence of the word `BAD` is published as an error
//!     diagnostic, and `MEH` as a warning — recomputed on didOpen and
//!     didChange, so incremental sync is verified by whether the
//!     diagnostics follow the edit;
//!   * completion offers a fixed set of items, one of which carries a
//!     `textEdit` and needs `completionItem/resolve` for its docs;
//!   * hover reports the byte offset and the word under the cursor;
//!   * definition/declaration/typeDefinition point at the FIRST
//!     occurrence of that word, references at all of them;
//!   * documentSymbol reports every `fn <name>` line;
//!   * rename returns a workspace edit renaming every occurrence;
//!   * formatting strips trailing whitespace from every line;
//!   * signature help reports a fixed two-parameter signature whose
//!     ACTIVE parameter is the number of commas between the enclosing
//!     `(` and the cursor, so "does the client follow the caret" is
//!     observable;
//!   * code actions offer all three shapes that occur in the wild — an
//!     inline `edit`, a `command` (answered with `workspace/applyEdit`)
//!     and one carrying neither, which needs `codeAction/resolve`;
//!   * inlay hints put ` [<line>]` at the end of every line inside the
//!     REQUESTED RANGE and nowhere else, so a client that asks for the
//!     whole document, or renders hints outside the answer, shows up;
//!   * semantic tokens classify every identifier run as keyword,
//!     function (after `fn `) or variable, with a `full/delta` reply
//!     that replaces the whole array.
//!
//! `--utf8` makes it negotiate `positionEncoding: utf-8`, which is how
//! the test rig checks both encodings against the same document.
//!
//! ## The didOpen report
//!
//! With `SKETERM_LSP_STUB_REPORT=<path>` set, the stub writes
//! `didopen_len=<N>` there the moment `textDocument/didOpen` arrives.
//! That is the regression fence for a bug the client shipped with for
//! months: `didOpen` carried ZERO bytes and the content followed as a
//! full-replace `didChange`. Sync was still correct, so nothing failed —
//! only a rig that can see the didOpen payload itself can catch it.

const std = @import("std");
const c = @import("c.zig").c;
const rpc = @import("lsp/rpc.zig");

var doc_text: std.ArrayList(u8) = .empty;
var doc_uri: std.ArrayList(u8) = .empty;
var utf8_mode = false;
/// `--range-only`: advertise `semanticTokens/range` and NOT `full`, the
/// shape a client that only implements `full` treats as no provider at
/// all. Exists so the range path has a real server behind it.
var range_only = false;
/// `--rename-multi`: answer `textDocument/rename` with a
/// `documentChanges` array naming the open document, a SIBLING file the
/// editor has not opened, and a `create` file operation — the three
/// outcomes a client's WorkspaceEdit applier has to tell apart.
var rename_multi = false;
var alloc: std.mem.Allocator = undefined;
/// The packed semantic-token array we last sent, and the id that names
/// it — what a `full/delta` request quotes back.
var sem_last: std.ArrayList(u32) = .empty;
var sem_result_id: u32 = 0;
/// Next id for a server->client request (`workspace/applyEdit`).
var next_server_id: i64 = 10_000;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    alloc = gpa_state.allocator();
    for (init.args.vector) |arg| {
        const s = std.mem.span(arg);
        if (std.mem.eql(u8, s, "--utf8")) utf8_mode = true;
        if (std.mem.eql(u8, s, "--range-only")) range_only = true;
        if (std.mem.eql(u8, s, "--rename-multi")) rename_multi = true;
    }

    var reader = rpc.Reader{};
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) break;
        reader.feed(alloc, buf[0..@intCast(n)]) catch break;
        while (true) {
            const body = (reader.next() catch break) orelse break;
            if (handle(body)) return 0;
        }
    }
    return 0;
}

/// @return true when the server should exit.
fn handle(body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer parsed.deinit();
    const env = rpc.classify(parsed.value);
    if (env.kind == .notification) {
        if (std.mem.eql(u8, env.method, "exit")) return true;
        if (std.mem.eql(u8, env.method, "textDocument/didOpen")) {
            const td = objGet(env.params, "textDocument") orelse return false;
            const text = strOf(objGet(td, "text")) orelse "";
            reportDidOpen(text.len);
            setDoc(strOf(objGet(td, "uri")) orelse "", text);
            publishDiagnostics();
        } else if (std.mem.eql(u8, env.method, "textDocument/didChange")) {
            applyChanges(env.params);
            publishDiagnostics();
        }
        return false;
    }
    if (env.kind != .request) return false;
    const id = env.id orelse return false;

    if (std.mem.eql(u8, env.method, "initialize")) {
        replyRaw(id, initializeResult());
    } else if (std.mem.eql(u8, env.method, "shutdown")) {
        replyRaw(id, "null");
    } else if (std.mem.eql(u8, env.method, "textDocument/completion")) {
        replyRaw(id, COMPLETION_RESULT);
    } else if (std.mem.eql(u8, env.method, "completionItem/resolve")) {
        replyResolve(id, env.params);
    } else if (std.mem.eql(u8, env.method, "textDocument/hover")) {
        replyHover(id, env.params);
    } else if (std.mem.eql(u8, env.method, "textDocument/definition") or
        std.mem.eql(u8, env.method, "textDocument/declaration") or
        std.mem.eql(u8, env.method, "textDocument/typeDefinition"))
    {
        replyDefinition(id, env.params, false);
    } else if (std.mem.eql(u8, env.method, "textDocument/references")) {
        replyDefinition(id, env.params, true);
    } else if (std.mem.eql(u8, env.method, "textDocument/documentSymbol")) {
        replySymbols(id);
    } else if (std.mem.eql(u8, env.method, "workspace/symbol")) {
        replySymbols(id);
    } else if (std.mem.eql(u8, env.method, "textDocument/rename")) {
        replyRename(id, env.params);
    } else if (std.mem.eql(u8, env.method, "textDocument/formatting") or
        std.mem.eql(u8, env.method, "textDocument/rangeFormatting"))
    {
        replyFormatting(id);
    } else if (std.mem.eql(u8, env.method, "textDocument/signatureHelp")) {
        replySignatureHelp(id, env.params);
    } else if (std.mem.eql(u8, env.method, "textDocument/codeAction")) {
        replyCodeActions(id, env.params);
    } else if (std.mem.eql(u8, env.method, "codeAction/resolve")) {
        replyResolvedAction(id, env.params);
    } else if (std.mem.eql(u8, env.method, "workspace/executeCommand")) {
        replyRaw(id, "null");
        // The work of a command arrives as a server->client edit — the
        // shape a client has to support for command-carrying actions.
        pushApplyEdit();
    } else if (std.mem.eql(u8, env.method, "textDocument/inlayHint")) {
        replyInlayHints(id, env.params);
    } else if (std.mem.eql(u8, env.method, "inlayHint/resolve")) {
        replyResolvedHint(id, env.params);
    } else if (std.mem.eql(u8, env.method, "textDocument/semanticTokens/full")) {
        replySemanticTokens(id, false, null);
    } else if (std.mem.eql(u8, env.method, "textDocument/semanticTokens/full/delta")) {
        replySemanticTokens(id, true, null);
    } else if (std.mem.eql(u8, env.method, "textDocument/semanticTokens/range")) {
        replySemanticTokens(id, false, env.params);
    } else {
        replyErr(id, -32601, "unsupported");
    }
    return false;
}

fn initializeResult() []const u8 {
    if (range_only) {
        return if (utf8_mode)
            "{\"positionEncoding\":\"utf-8\",\"capabilities\":" ++ CAPS_RANGE_ONLY ++ "}"
        else
            "{\"positionEncoding\":\"utf-16\",\"capabilities\":" ++ CAPS_RANGE_ONLY ++ "}";
    }
    return if (utf8_mode)
        "{\"positionEncoding\":\"utf-8\",\"capabilities\":" ++ CAPS ++ "}"
    else
        "{\"positionEncoding\":\"utf-16\",\"capabilities\":" ++ CAPS ++ "}";
}

const CAPS =
    \\{"textDocumentSync":{"openClose":true,"change":2,"save":{"includeText":false}},
    \\"completionProvider":{"resolveProvider":true,"triggerCharacters":["."]},
    \\"hoverProvider":true,"definitionProvider":true,"declarationProvider":true,
    \\"typeDefinitionProvider":true,"referencesProvider":true,
    \\"documentSymbolProvider":true,"workspaceSymbolProvider":true,
    \\"renameProvider":true,
    \\"documentFormattingProvider":true,"documentRangeFormattingProvider":true,
    \\"signatureHelpProvider":{"triggerCharacters":["("],"retriggerCharacters":[","]},
    \\"codeActionProvider":{"resolveProvider":true},
    \\"executeCommandProvider":{"commands":["stub.fixAllBad"]},
    \\"inlayHintProvider":{"resolveProvider":true},
    \\"semanticTokensProvider":{"legend":{"tokenTypes":["function","variable","keyword","property"],"tokenModifiers":["declaration","readonly","deprecated","defaultLibrary"]},"full":{"delta":true},"range":true}}
;

/// Same server minus `full`: the shape a client that only implements
/// `semanticTokens/full` treats as offering nothing at all. Selected
/// with `SKETERM_LSP_STUB_RANGE_ONLY=1`.
const CAPS_RANGE_ONLY =
    \\{"textDocumentSync":{"openClose":true,"change":2,"save":{"includeText":false}},
    \\"hoverProvider":true,
    \\"inlayHintProvider":{"resolveProvider":true},
    \\"semanticTokensProvider":{"legend":{"tokenTypes":["function","variable","keyword","property"],"tokenModifiers":["declaration","readonly","deprecated","defaultLibrary"]},"range":true}}
;

const COMPLETION_RESULT =
    \\{"isIncomplete":false,"items":[
    \\{"label":"stubAlpha","kind":3,"detail":"fn () void","insertText":"stubAlpha"},
    \\{"label":"stubBeta","kind":6,"detail":"method","insertText":"stubBeta"},
    \\{"label":"stubGamma","kind":13,"detail":"const"}]}
;

// ---- document -----------------------------------------------------------

fn setDoc(uri: []const u8, text: []const u8) void {
    doc_uri.clearRetainingCapacity();
    doc_uri.appendSlice(alloc, uri) catch {};
    doc_text.clearRetainingCapacity();
    doc_text.appendSlice(alloc, text) catch {};
}

/// Apply `contentChanges` in array order — a ranged change against the
/// text the previous ones produced, exactly as the spec requires. This
/// is what makes the rig's diagnostics a real test of incremental sync:
/// if the client's ranges are wrong, the stub's copy diverges and the
/// diagnostics land in the wrong place.
fn applyChanges(params: std.json.Value) void {
    const arr = objGet(params, "contentChanges") orelse return;
    if (arr != .array) return;
    for (arr.array.items) |ch| {
        const text = strOf(objGet(ch, "text")) orelse "";
        const rng = objGet(ch, "range") orelse {
            doc_text.clearRetainingCapacity();
            doc_text.appendSlice(alloc, text) catch {};
            continue;
        };
        const s = offsetOf(objGet(rng, "start") orelse .null);
        const e = offsetOf(objGet(rng, "end") orelse .null);
        if (s > doc_text.items.len or e > doc_text.items.len or e < s) continue;
        doc_text.replaceRange(alloc, s, e - s, text) catch {};
    }
}

/// LSP position -> byte offset in our copy, in whichever encoding was
/// negotiated. Deliberately an independent implementation of the same
/// arithmetic the client does, so a shared bug cannot hide.
fn offsetOf(p: std.json.Value) usize {
    const line = intOf(objGet(p, "line"));
    const character = intOf(objGet(p, "character"));
    var off: usize = 0;
    var l: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, doc_text.items, off, '\n') orelse return doc_text.items.len;
        off = nl + 1;
    }
    const line_end = std.mem.indexOfScalarPos(u8, doc_text.items, off, '\n') orelse doc_text.items.len;
    if (utf8_mode) return @min(off + character, line_end);
    var units: usize = 0;
    while (off < line_end and units < character) {
        const lead = doc_text.items[off];
        const len = std.unicode.utf8ByteSequenceLength(lead) catch 1;
        units += if (lead >= 0xF0) 2 else 1;
        off += @min(len, line_end - off);
    }
    return off;
}

fn positionOf(offset: usize) struct { line: usize, character: usize } {
    var line: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset and i < doc_text.items.len) : (i += 1) {
        if (doc_text.items[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    if (utf8_mode) return .{ .line = line, .character = offset - line_start };
    var units: usize = 0;
    var j = line_start;
    while (j < offset and j < doc_text.items.len) : (j += 1) {
        const b = doc_text.items[j];
        if (b & 0xC0 == 0x80) continue;
        units += if (b >= 0xF0) 2 else 1;
    }
    return .{ .line = line, .character = units };
}

// ---- replies -------------------------------------------------------------

fn send(body: []const u8) void {
    var head: [48]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    writeAll(h);
    writeAll(body);
}

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(1, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn replyRaw(id: i64, result: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result }) catch return;
    send(out.items);
}

fn replyErr(id: i64, code: i64, msg: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id, code, msg },
    ) catch return;
    send(out.items);
}

fn appendRange(out: *std.ArrayList(u8), start: usize, end: usize) void {
    const s = positionOf(start);
    const e = positionOf(end);
    out.print(
        alloc,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ s.line, s.character, e.line, e.character },
    ) catch {};
}

fn publishDiagnostics() void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"") catch return;
    out.appendSlice(alloc, doc_uri.items) catch return;
    out.appendSlice(alloc, "\",\"diagnostics\":[") catch return;
    var first = true;
    inline for (.{ .{ "BAD", 1, "stub: BAD is not allowed" }, .{ "MEH", 2, "stub: MEH is discouraged" } }) |spec| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, doc_text.items, from, spec[0])) |at| {
            if (!first) out.append(alloc, ',') catch return;
            first = false;
            out.appendSlice(alloc, "{\"range\":") catch return;
            appendRange(&out, at, at + spec[0].len);
            out.print(alloc, ",\"severity\":{d},\"source\":\"stub\",\"message\":\"{s}\"}}", .{ spec[1], spec[2] }) catch return;
            from = at + spec[0].len;
        }
    }
    out.appendSlice(alloc, "]}}") catch return;
    send(out.items);
}

fn replyResolve(id: i64, params: std.json.Value) void {
    const label = strOf(objGet(params, "label")) orelse "?";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(
        alloc,
        "{{\"label\":\"{s}\",\"documentation\":{{\"kind\":\"plaintext\",\"value\":\"stub docs for {s}\"}}}}",
        .{ label, label },
    ) catch return;
    replyRaw(id, out.items);
}

/// The word (identifier run) around `offset`.
fn wordAt(offset: usize) struct { start: usize, end: usize } {
    const t = doc_text.items;
    var s = @min(offset, t.len);
    while (s > 0 and isWordy(t[s - 1])) s -= 1;
    var e = @min(offset, t.len);
    while (e < t.len and isWordy(t[e])) e += 1;
    return .{ .start = s, .end = e };
}

fn isWordy(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch >= 0x80;
}

fn replyHover(id: i64, params: std.json.Value) void {
    const off = offsetOf(objGet(params, "position") orelse .null);
    const w = wordAt(off);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(
        alloc,
        "{{\"contents\":{{\"kind\":\"plaintext\",\"value\":\"stub hover: word='{s}' offset={d}\"}}}}",
        .{ doc_text.items[w.start..w.end], off },
    ) catch return;
    replyRaw(id, out.items);
}

fn replyDefinition(id: i64, params: std.json.Value, all: bool) void {
    const off = offsetOf(objGet(params, "position") orelse .null);
    const w = wordAt(off);
    if (w.end <= w.start) {
        replyRaw(id, "null");
        return;
    }
    const word = doc_text.items[w.start..w.end];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '[') catch return;
    var from: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, word)) |at| {
        if (n > 0) out.append(alloc, ',') catch return;
        out.appendSlice(alloc, "{\"uri\":\"") catch return;
        out.appendSlice(alloc, doc_uri.items) catch return;
        out.appendSlice(alloc, "\",\"range\":") catch return;
        appendRange(&out, at, at + word.len);
        out.append(alloc, '}') catch return;
        n += 1;
        from = at + word.len;
        if (!all) break;
    }
    out.append(alloc, ']') catch return;
    replyRaw(id, out.items);
}

fn replySymbols(id: i64) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '[') catch return;
    var from: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, "fn ")) |at| {
        const name_start = at + 3;
        var name_end = name_start;
        while (name_end < doc_text.items.len and isWordy(doc_text.items[name_end])) name_end += 1;
        if (name_end > name_start) {
            if (n > 0) out.append(alloc, ',') catch return;
            out.print(alloc, "{{\"name\":\"{s}\",\"kind\":12,\"range\":", .{doc_text.items[name_start..name_end]}) catch return;
            appendRange(&out, at, name_end);
            out.appendSlice(alloc, ",\"selectionRange\":") catch return;
            appendRange(&out, name_start, name_end);
            out.append(alloc, '}') catch return;
            n += 1;
        }
        from = at + 3;
    }
    out.append(alloc, ']') catch return;
    replyRaw(id, out.items);
}

fn replyRename(id: i64, params: std.json.Value) void {
    const off = offsetOf(objGet(params, "position") orelse .null);
    const new_name = strOf(objGet(params, "newName")) orelse "renamed";
    const w = wordAt(off);
    if (w.end <= w.start) {
        replyRaw(id, "null");
        return;
    }
    const word = doc_text.items[w.start..w.end];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"changes\":{\"") catch return;
    out.appendSlice(alloc, doc_uri.items) catch return;
    out.appendSlice(alloc, "\":[") catch return;
    var from: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, word)) |at| {
        if (n > 0) out.append(alloc, ',') catch return;
        out.appendSlice(alloc, "{\"range\":") catch return;
        appendRange(&out, at, at + word.len);
        out.print(alloc, ",\"newText\":\"{s}\"}}", .{new_name}) catch return;
        n += 1;
        from = at + word.len;
    }
    out.appendSlice(alloc, "]}}") catch return;
    if (rename_multi) {
        replyRenameMulti(id, word, new_name);
        return;
    }
    replyRaw(id, out.items);
}

/// The `documentChanges` shape, naming three things at once: the open
/// document, a sibling the editor has NOT opened, and a file operation.
fn replyRenameMulti(id: i64, word: []const u8, new_name: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, doc_uri.items, '/') orelse {
        replyRaw(id, "null");
        return;
    };
    const dir = doc_uri.items[0 .. slash + 1];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"") catch return;
    out.appendSlice(alloc, doc_uri.items) catch return;
    out.appendSlice(alloc, "\",\"version\":null},\"edits\":[") catch return;
    var from: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, word)) |at| {
        if (n > 0) out.append(alloc, ',') catch return;
        out.appendSlice(alloc, "{\"range\":") catch return;
        appendRange(&out, at, at + word.len);
        out.print(alloc, ",\"newText\":\"{s}\"}}", .{new_name}) catch return;
        n += 1;
        from = at + word.len;
    }
    // The sibling: line 0, characters 0..0 — a pure insertion, so it
    // works whatever that file happens to contain.
    out.print(
        alloc,
        "]}},{{\"textDocument\":{{\"uri\":\"{s}other.zig\",\"version\":null}}," ++
            "\"edits\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}}," ++
            "\"end\":{{\"line\":0,\"character\":0}}}},\"newText\":\"// touched by {s}\\n\"}}]}}," ++
            "{{\"kind\":\"create\",\"uri\":\"{s}created.zig\"}}]}}",
        .{ dir, new_name, dir },
    ) catch return;
    replyRaw(id, out.items);
}

/// One TextEdit per line that has trailing whitespace. Several
/// non-overlapping edits in one response is the shape the client has to
/// fold into a SINGLE undo unit.
fn replyFormatting(id: i64) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '[') catch return;
    var n: usize = 0;
    var line_start: usize = 0;
    while (line_start <= doc_text.items.len) {
        const line_end = std.mem.indexOfScalarPos(u8, doc_text.items, line_start, '\n') orelse doc_text.items.len;
        var trim_end = line_end;
        while (trim_end > line_start and (doc_text.items[trim_end - 1] == ' ' or doc_text.items[trim_end - 1] == '\t')) {
            trim_end -= 1;
        }
        if (trim_end < line_end) {
            if (n > 0) out.append(alloc, ',') catch return;
            out.appendSlice(alloc, "{\"range\":") catch return;
            appendRange(&out, trim_end, line_end);
            out.appendSlice(alloc, ",\"newText\":\"\"}") catch return;
            n += 1;
        }
        if (line_end >= doc_text.items.len) break;
        line_start = line_end + 1;
    }
    out.append(alloc, ']') catch return;
    replyRaw(id, out.items);
}

// ---- didOpen report ---------------------------------------------------------

/// Record how many bytes `didOpen` actually carried. See the module
/// header: this is the only place that number is observable, and a
/// client that opens an empty document and follows it with a
/// full-replace `didChange` is otherwise indistinguishable from a
/// correct one.
fn reportDidOpen(len: usize) void {
    const path = c.getenv("SKETERM_LSP_STUB_REPORT") orelse return;
    const f = c.fopen(path, "wb") orelse return;
    defer _ = c.fclose(f);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "didopen_len={d}\n", .{len}) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}

// ---- signature help ---------------------------------------------------------

/// A fixed signature; the ACTIVE parameter is derived from the text, so
/// a client that fails to re-request as the caret moves shows a stale
/// index rather than nothing at all.
fn replySignatureHelp(id: i64, params: std.json.Value) void {
    const off = offsetOf(objGet(params, "position") orelse .null);
    // Walk back to the enclosing '(' counting top-level commas.
    var i = @min(off, doc_text.items.len);
    var commas: usize = 0;
    var depth: usize = 0;
    var found = false;
    while (i > 0) {
        i -= 1;
        const ch = doc_text.items[i];
        if (ch == ')') depth += 1;
        if (ch == ',' and depth == 0) commas += 1;
        if (ch == '(') {
            if (depth == 0) {
                found = true;
                break;
            }
            depth -= 1;
        }
        if (ch == '\n') break;
    }
    if (!found) {
        replyRaw(id, "null");
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(alloc,
        \\{{"signatures":[{{"label":"stubCall(first: i32, second: i32)",
        \\"documentation":{{"kind":"plaintext","value":"stub signature"}},
        \\"parameters":[{{"label":"first: i32","documentation":"the first one"}},
        \\{{"label":"second: i32","documentation":"the second one"}}]}}],
        \\"activeSignature":0,"activeParameter":{d}}}
    , .{@min(commas, 1)}) catch return;
    replyRaw(id, out.items);
}

// ---- code actions -----------------------------------------------------------

/// Three actions, one of each shape a real server produces.
fn replyCodeActions(id: i64, params: std.json.Value) void {
    const rng = objGet(params, "range") orelse std.json.Value.null;
    const s = offsetOf(objGet(rng, "start") orelse .null);
    const e = offsetOf(objGet(rng, "end") orelse .null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '[') catch return;
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, "BAD")) |at| {
        from = at + 3;
        if (at + 3 < s or at > e) continue;
        if (n > 0) out.append(alloc, ',') catch return;
        out.appendSlice(alloc, "{\"title\":\"Replace BAD with GOOD\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"") catch return;
        out.appendSlice(alloc, doc_uri.items) catch return;
        out.appendSlice(alloc, "\":[{\"range\":") catch return;
        appendRange(&out, at, at + 3);
        out.appendSlice(alloc, ",\"newText\":\"GOOD\"}]}}}") catch return;
        n += 1;
    }
    // Always offered, whatever the range: a command-only action and a
    // lazily-resolved one.
    if (n > 0) out.append(alloc, ',') catch return;
    out.appendSlice(alloc,
        \\{"title":"Fix all BAD (command)","kind":"source.fixAll",
        \\"command":{"title":"fix","command":"stub.fixAllBad","arguments":[1]}},
        \\{"title":"Append a stub marker (resolved)","kind":"refactor","data":{"stub":true}}
    ) catch return;
    out.append(alloc, ']') catch return;
    replyRaw(id, out.items);
}

/// The lazily-resolved action's edit: append a marker at the very end.
fn replyResolvedAction(id: i64, params: std.json.Value) void {
    const title = strOf(objGet(params, "title")) orelse "resolved";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(alloc, "{{\"title\":\"{s}\",\"kind\":\"refactor\",\"edit\":{{\"changes\":{{\"", .{title}) catch return;
    out.appendSlice(alloc, doc_uri.items) catch return;
    out.appendSlice(alloc, "\":[{\"range\":") catch return;
    appendRange(&out, doc_text.items.len, doc_text.items.len);
    out.appendSlice(alloc, ",\"newText\":\"// stub-resolved\\n\"}]}}}") catch return;
    replyRaw(id, out.items);
}

/// `workspace/applyEdit`: replace every BAD with GOOD, as a server
/// -> client REQUEST (the client must answer it or we would block).
fn pushApplyEdit() void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/applyEdit\",\"params\":{{\"edit\":{{\"changes\":{{\"",
        .{next_server_id},
    ) catch return;
    next_server_id += 1;
    out.appendSlice(alloc, doc_uri.items) catch return;
    out.appendSlice(alloc, "\":[") catch return;
    var from: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, doc_text.items, from, "BAD")) |at| {
        if (n > 0) out.append(alloc, ',') catch return;
        out.appendSlice(alloc, "{\"range\":") catch return;
        appendRange(&out, at, at + 3);
        out.appendSlice(alloc, ",\"newText\":\"GOOD\"}") catch return;
        n += 1;
        from = at + 3;
    }
    out.appendSlice(alloc, "]}}}}") catch return;
    send(out.items);
}

// ---- inlay hints ------------------------------------------------------------

/// ` [<line>]` at the end of every line INSIDE the requested range.
fn replyInlayHints(id: i64, params: std.json.Value) void {
    const rng = objGet(params, "range") orelse std.json.Value.null;
    const from_line = intOf(objGet(objGet(rng, "start") orelse .null, "line"));
    const to_line = intOf(objGet(objGet(rng, "end") orelse .null, "line"));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '[') catch return;
    var n: usize = 0;
    var line: usize = 0;
    var off: usize = 0;
    while (off <= doc_text.items.len) {
        const line_end = std.mem.indexOfScalarPos(u8, doc_text.items, off, '\n') orelse doc_text.items.len;
        if (line >= from_line and line <= to_line and line_end > off) {
            if (n > 0) out.append(alloc, ',') catch return;
            const p = positionOf(line_end);
            out.print(
                alloc,
                "{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\" [{d}]\"," ++
                    "\"kind\":1,\"paddingLeft\":true,\"data\":{d}}}",
                .{ p.line, p.character, line, line + 100 },
            ) catch return;
            n += 1;
        }
        if (line_end >= doc_text.items.len) break;
        off = line_end + 1;
        line += 1;
    }
    out.append(alloc, ']') catch return;
    replyRaw(id, out.items);
}

/// `inlayHint/resolve`: echo the hint back with a `tooltip` filled in.
/// The label is echoed verbatim so a client that reconstructs the hint
/// instead of keeping the server's own object gets caught — the tooltip
/// quotes the `data` field, which only the original object carries.
fn replyResolvedHint(id: i64, params: std.json.Value) void {
    const data = intOf(objGet(params, "data"));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const p = objGet(params, "position") orelse std.json.Value.null;
    out.print(
        alloc,
        "{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"resolved\"," ++
            "\"tooltip\":{{\"kind\":\"plaintext\",\"value\":\"stub tooltip for data={d}\"}}}}",
        .{ intOf(objGet(p, "line")), intOf(objGet(p, "character")), data },
    ) catch return;
    replyRaw(id, out.items);
}

// ---- semantic tokens --------------------------------------------------------

const KEYWORDS = [_][]const u8{ "fn", "const", "var", "return", "void", "pub", "static", "int" };

/// One token per identifier run: keyword, function (right after `fn `)
/// or variable. Encoded relative, exactly as the wire format wants.
fn buildSemanticTokens(out: *std.ArrayList(u32), from_line: usize, to_line: usize) void {
    out.clearRetainingCapacity();
    var prev_line: usize = 0;
    var prev_char: usize = 0;
    var i: usize = 0;
    var last_word_was_fn = false;
    while (i < doc_text.items.len) {
        if (!isWordy(doc_text.items[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < doc_text.items.len and isWordy(doc_text.items[i])) i += 1;
        const word = doc_text.items[start..i];
        var kind: u32 = 1; // variable
        var is_fn_kw = false;
        for (KEYWORDS) |kw| {
            if (std.mem.eql(u8, word, kw)) {
                kind = 2;
                is_fn_kw = std.mem.eql(u8, kw, "fn");
                break;
            }
        }
        if (kind != 2 and last_word_was_fn) kind = 0; // function
        // The rig's marker: a word no grammar classifies specially, so
        // seeing the `property` colour on screen can ONLY mean the
        // semantic tokens were applied.
        if (std.mem.eql(u8, word, "SEM")) kind = 3;
        // …and two more that additionally carry a MODIFIER, so the
        // modifier band has a real server driving it. Legend order is
        // declaration, readonly, deprecated, defaultLibrary.
        var mods: u32 = 0;
        if (std.mem.eql(u8, word, "SEMRO")) {
            kind = 3;
            mods = 1 << 1; // readonly
        } else if (std.mem.eql(u8, word, "SEMDEP")) {
            kind = 0;
            mods = 1 << 2; // deprecated
        } else if (std.mem.eql(u8, word, "SEMLIB")) {
            kind = 0;
            mods = 1 << 3; // defaultLibrary
        }
        last_word_was_fn = is_fn_kw;

        const ps = positionOf(start);
        const pe = positionOf(i);
        // A token never spans lines here, so the length is the
        // character delta on the line.
        if (pe.line != ps.line) continue;
        if (ps.line < from_line or ps.line >= to_line) continue;
        const dl = ps.line - prev_line;
        const dc = if (dl == 0) ps.character - prev_char else ps.character;
        out.append(alloc, @intCast(dl)) catch return;
        out.append(alloc, @intCast(dc)) catch return;
        out.append(alloc, @intCast(pe.character - ps.character)) catch return;
        out.append(alloc, kind) catch return;
        out.append(alloc, mods) catch return;
        prev_line = ps.line;
        prev_char = ps.character;
    }
}

/// `range` non-null = a `semanticTokens/range` request, whose answer
/// must contain ONLY tokens inside it. Same reply shape as `full`.
fn replySemanticTokens(id: i64, delta: bool, range: ?std.json.Value) void {
    var from_line: usize = 0;
    var to_line: usize = std.math.maxInt(usize);
    if (range) |p| {
        const rng = objGet(p, "range") orelse std.json.Value.null;
        from_line = intOf(objGet(objGet(rng, "start") orelse .null, "line"));
        to_line = intOf(objGet(objGet(rng, "end") orelse .null, "line"));
    }
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(alloc);
    buildSemanticTokens(&fresh, from_line, to_line);
    sem_result_id += 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (delta) {
        // One splice replacing the whole previous array: the simplest
        // legal delta, and it still exercises the client's splice.
        out.print(
            alloc,
            "{{\"resultId\":\"{d}\",\"edits\":[{{\"start\":0,\"deleteCount\":{d},\"data\":[",
            .{ sem_result_id, sem_last.items.len },
        ) catch return;
    } else {
        out.print(alloc, "{{\"resultId\":\"{d}\",\"data\":[", .{sem_result_id}) catch return;
    }
    for (fresh.items, 0..) |v, k| {
        if (k > 0) out.append(alloc, ',') catch return;
        out.print(alloc, "{d}", .{v}) catch return;
    }
    out.appendSlice(alloc, if (delta) "]}]}" else "]}") catch return;
    sem_last.clearRetainingCapacity();
    sem_last.appendSlice(alloc, fresh.items) catch {};
    replyRaw(id, out.items);
}

// ---- json helpers ----------------------------------------------------------

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?std.json.Value) usize {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

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
//!   * formatting strips trailing whitespace from every line.
//!
//! `--utf8` makes it negotiate `positionEncoding: utf-8`, which is how
//! the test rig checks both encodings against the same document.

const std = @import("std");
const c = @import("c.zig").c;
const rpc = @import("lsp/rpc.zig");

var doc_text: std.ArrayList(u8) = .empty;
var doc_uri: std.ArrayList(u8) = .empty;
var utf8_mode = false;
var alloc: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    alloc = gpa_state.allocator();
    for (init.args.vector) |arg| {
        const s = std.mem.span(arg);
        if (std.mem.eql(u8, s, "--utf8")) utf8_mode = true;
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
            setDoc(strOf(objGet(td, "uri")) orelse "", strOf(objGet(td, "text")) orelse "");
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
    } else {
        replyErr(id, -32601, "unsupported");
    }
    return false;
}

fn initializeResult() []const u8 {
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
    \\"documentFormattingProvider":true,"documentRangeFormattingProvider":true}
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

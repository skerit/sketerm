//! smoke-e2e stage: the editor's language coverage, driven through the
//! entry points a user has. Real files are opened with `new-editor-tab`,
//! keys go through the real seat (Tab, Ctrl+/), a palette command goes
//! through the real palette, and the verdicts read back the document
//! (`get-text`) and the view's own language state (`editor-lang`, the
//! same functions the renderer and the status line call).
//!
//! Covered: Python, a Makefile and TypeScript highlighted by their
//! grammars; toggle-comment writing each language's own token; bracket
//! matching refusing a bracket inside a string (tree path) and in a
//! grammar-less language (lexical path, Ruby); Tab inserting a hard tab
//! in a Makefile; `.editorconfig` beating the file's content; and the
//! per-tab indentation override from the command palette.

const std = @import("std");
const c = @import("../c.zig").c;
const appdrive = @import("../ipc/appdrive.zig");
const ctlsock = @import("ctlsock.zig");
const rigwin = @import("rigwin.zig");

const Info = struct {
    language: []const u8 = "",
    lsp_id: []const u8 = "",
    grammar: bool = false,
    highlighted: bool = false,
    indent_style: []const u8 = "",
    indent_size: u16 = 0,
    tab_width: u16 = 0,
    indent_source: []const u8 = "",
    comment_open: []const u8 = "",
    comment_close: []const u8 = "",
    kind_at: []const u8 = "",
    pair_open: ?usize = null,
    pair_close: ?usize = null,
    status: []const u8 = "",
};

const Reply = struct { ok: bool = false, lang: Info = .{} };
const TextReply = struct { ok: bool = false, text: []const u8 = "" };

const Ctx = struct {
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    sock: [:0]const u8,
    arena: std.heap.ArenaAllocator,
    panes: std.ArrayList(u32) = .empty,

    fn a(self: *Ctx) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn roundtrip(self: *Ctx, line: []const u8) ?[]u8 {
        const r = ctlsock.roundtrip(self.allocator, self.app, self.sock, line) orelse return null;
        defer self.allocator.free(r);
        return self.a().dupe(u8, r) catch null;
    }

    /// `editor-lang` for `pane`, optionally at `offset`; null until the
    /// document has loaded.
    fn info(self: *Ctx, pane: u32, offset: ?usize) ?Info {
        const req = if (offset) |o|
            std.fmt.allocPrint(self.a(), "{{\"cmd\":\"editor-lang\",\"pane\":{d},\"data\":\"{d}\"}}\n", .{ pane, o }) catch return null
        else
            std.fmt.allocPrint(self.a(), "{{\"cmd\":\"editor-lang\",\"pane\":{d}}}\n", .{pane}) catch return null;
        const reply = self.roundtrip(req) orelse return null;
        const parsed = std.json.parseFromSliceLeaky(Reply, self.a(), reply, .{ .ignore_unknown_fields = true }) catch return null;
        if (!parsed.ok) return null;
        return parsed.lang;
    }

    fn waitInfo(self: *Ctx, pane: u32, offset: ?usize) ?Info {
        var waited: u32 = 0;
        while (waited < 15_000) : (waited += 100) {
            if (self.info(pane, offset)) |i| return i;
            _ = self.app.pumpOnce(100);
        }
        return null;
    }

    fn text(self: *Ctx, pane: u32) ?[]const u8 {
        const req = std.fmt.allocPrint(self.a(), "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{pane}) catch return null;
        const reply = self.roundtrip(req) orelse return null;
        const parsed = std.json.parseFromSliceLeaky(TextReply, self.a(), reply, .{ .ignore_unknown_fields = true }) catch return null;
        if (!parsed.ok) return null;
        return parsed.text;
    }

    /// Poll the document until it starts with `prefix`; on a miss, say
    /// what the document and the status line held instead.
    fn waitTextPrefix(self: *Ctx, pane: u32, prefix: []const u8) bool {
        var waited: u32 = 0;
        var last: []const u8 = "";
        while (waited < 10_000) : (waited += 100) {
            if (self.text(pane)) |t| {
                if (std.mem.startsWith(u8, t, prefix)) return true;
                last = t;
            }
            _ = self.app.pumpOnce(100);
        }
        const status = if (self.info(pane, null)) |i| i.status else "?";
        std.debug.print("smoke-e2e editor-lang: document is '{s}', status '{s}'\n", .{ last, status });
        return false;
    }

    fn open(self: *Ctx, path: []const u8) ?u32 {
        const req = std.fmt.allocPrint(self.a(), "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{path}) catch return null;
        const reply = self.roundtrip(req) orelse return null;
        const at = std.mem.indexOf(u8, reply, "\"pane\":") orelse return null;
        var i = at + "\"pane\":".len;
        var v: u32 = 0;
        var any = false;
        while (i < reply.len and std.ascii.isDigit(reply[i])) : (i += 1) {
            v = v * 10 + (reply[i] - '0');
            any = true;
        }
        if (!any) return null;
        self.panes.append(self.allocator, v) catch {};
        return v;
    }

    /// Focus `pane`, give its canvas the keyboard as a click does, and
    /// put the caret back at the document start (the click moved it).
    fn focus(self: *Ctx, pane: u32) bool {
        const req = std.fmt.allocPrint(self.a(), "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{pane}) catch return false;
        const reply = self.roundtrip(req) orelse return false;
        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) return false;
        _ = self.app.drainLive(1_000);
        if (self.app.windows.items.len == 0) return false;
        const w = rigwin.mainWin(self.app);
        self.app.clickEx(w.id, @as(f64, @floatFromInt(w.w)) / 2, @as(f64, @floatFromInt(w.h)) / 2, 1, 100, 1) catch return false;
        _ = self.app.waitIdle(300, 5_000);
        self.app.pressKey(null, "ctrl+home") catch return false;
        _ = self.app.waitIdle(200, 3_000);
        return true;
    }

    fn closeAll(self: *Ctx) void {
        for (self.panes.items) |p| {
            var buf: [96]u8 = undefined;
            // Saved first: a dirty editor tab turns close-pane into a
            // "Discard unsaved changes?" dialog, which stayed up over the
            // window and swallowed the next stage's keys.
            const save = std.fmt.bufPrint(&buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{p}) catch continue;
            if (ctlsock.roundtrip(self.allocator, self.app, self.sock, save)) |r| self.allocator.free(r);
            _ = self.app.waitIdle(200, 3_000);
            const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{p}) catch continue;
            if (ctlsock.roundtrip(self.allocator, self.app, self.sock, req)) |r| self.allocator.free(r);
            _ = self.app.waitIdle(200, 3_000);
        }
        self.panes.clearRetainingCapacity();
    }
};

fn writeFile(path: []const u8, body: []const u8) bool {
    var zbuf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return false;
    const fp = c.fopen(z.ptr, "wb") orelse return false;
    defer _ = c.fclose(fp);
    return c.fwrite(body.ptr, 1, body.len, fp) == body.len;
}

/// Create `path`; an existing directory is fine (a rerun in the same
/// runtime dir), and a real failure shows up as the fixture write.
fn mkdir(path: []const u8) void {
    var zbuf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    _ = c.mkdir(z.ptr, 0o755);
}

const PY_SRC =
    \\def f(a):
    \\    s = "(( not a bracket"
    \\    return g(a)
    \\
;
const MAKE_SRC = "all:\n\techo hi\n";
const TS_SRC =
    \\interface P { x: number }
    \\function g(p: P): string { return "[)" + p.x; }
    \\
;
const RB_SRC = "puts(\"(\", foo(1)) # )\n";
const EC_TEXT =
    \\root = true
    \\
    \\[*.py]
    \\indent_style = space
    \\indent_size = 2
    \\
;
const EC_PY_SRC = "def f():\n\treturn 1\n";

fn expectEq(got: []const u8, want: []const u8, comptime what: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, got, want)) return null;
    std.debug.print("smoke-e2e editor-lang: {s}: got '{s}', want '{s}'\n", .{ what, got, want });
    return "editor-lang: " ++ what ++ " is wrong";
}

pub fn stage(allocator: std.mem.Allocator, app: *appdrive.App, sock: [:0]const u8, rt: []const u8) ?[]const u8 {
    var ctx = Ctx{ .allocator = allocator, .app = app, .sock = sock, .arena = std.heap.ArenaAllocator.init(allocator) };
    defer ctx.arena.deinit();
    defer ctx.panes.deinit(allocator);
    defer ctx.closeAll();
    const a = ctx.a();

    const dir = std.fmt.allocPrint(a, "{s}/langs", .{rt}) catch return "fmt";
    const ec_dir = std.fmt.allocPrint(a, "{s}/langs/ec", .{rt}) catch return "fmt";
    mkdir(dir);
    mkdir(ec_dir);
    const py = std.fmt.allocPrint(a, "{s}/tool.py", .{dir}) catch return "fmt";
    const mk = std.fmt.allocPrint(a, "{s}/Makefile", .{dir}) catch return "fmt";
    const ts = std.fmt.allocPrint(a, "{s}/app.ts", .{dir}) catch return "fmt";
    const rb = std.fmt.allocPrint(a, "{s}/notes.rb", .{dir}) catch return "fmt";
    const ec = std.fmt.allocPrint(a, "{s}/.editorconfig", .{ec_dir}) catch return "fmt";
    const ec_py = std.fmt.allocPrint(a, "{s}/tabbed.py", .{ec_dir}) catch return "fmt";
    if (!writeFile(py, PY_SRC) or !writeFile(mk, MAKE_SRC) or !writeFile(ts, TS_SRC) or
        !writeFile(rb, RB_SRC) or !writeFile(ec, EC_TEXT) or !writeFile(ec_py, EC_PY_SRC))
        return "could not write the language fixtures";

    // ---- Python: grammar colours, tree brackets, `#` comments
    {
        const pane = ctx.open(py) orelse return "new-editor-tab for tool.py failed";
        const i = ctx.waitInfo(pane, 0) orelse return "tool.py never finished loading";
        if (expectEq(i.language, "Python", "tool.py language")) |e| return e;
        if (!i.grammar or !i.highlighted) return "tool.py is not highlighted by its grammar";
        if (expectEq(i.kind_at, "keyword", "tool.py kind of `def`")) |e| return e;
        if (expectEq(i.comment_open, "#", "Python comment token")) |e| return e;
        if (std.mem.indexOf(u8, i.status, "Python, Spaces: 4") == null) {
            std.debug.print("smoke-e2e editor-lang: status '{s}'\n", .{i.status});
            return "the status line does not show Python's language and indentation";
        }
        const in_str = std.mem.indexOf(u8, PY_SRC, "((").?;
        const s = ctx.info(pane, in_str) orelse return "editor-lang at the string failed";
        if (expectEq(s.kind_at, "string", "tool.py kind inside the string")) |e| return e;
        if (s.pair_open) |po| {
            if (po == in_str) return "tool.py: a bracket inside a string matched (tree path)";
        }
        const call = std.mem.indexOf(u8, PY_SRC, "g(a)").? + 1;
        const p = ctx.info(pane, call) orelse return "editor-lang at g( failed";
        if (p.pair_open != call or p.pair_close != call + 2) return "tool.py: g(a) did not pair its brackets";

        if (!ctx.focus(pane)) return "could not focus tool.py";
        app.pressKey(null, "ctrl+/") catch return "injecting Ctrl+/ failed";
        if (!ctx.waitTextPrefix(pane, "# def f(a):")) return "Ctrl+/ in tool.py did not write a `#` comment";
    }

    // ---- Makefile: grammar, and Tab writes a hard tab
    {
        const pane = ctx.open(mk) orelse return "new-editor-tab for Makefile failed";
        const i = ctx.waitInfo(pane, 0) orelse return "Makefile never finished loading";
        if (expectEq(i.language, "Makefile", "Makefile language")) |e| return e;
        if (!i.grammar or !i.highlighted) return "the Makefile is not highlighted by its grammar";
        if (expectEq(i.indent_style, "tabs", "Makefile indent style")) |e| return e;
        if (expectEq(i.indent_source, "language", "Makefile indent source")) |e| return e;
        if (expectEq(i.comment_open, "#", "Makefile comment token")) |e| return e;
        if (!ctx.focus(pane)) return "could not focus the Makefile";
        app.pressKey(null, "tab") catch return "injecting Tab failed";
        if (!ctx.waitTextPrefix(pane, "\tall:")) return "Tab in a Makefile did not insert a hard tab";
    }

    // ---- TypeScript: grammar colours, tree brackets, `//` comments
    {
        const pane = ctx.open(ts) orelse return "new-editor-tab for app.ts failed";
        const i = ctx.waitInfo(pane, 0) orelse return "app.ts never finished loading";
        if (expectEq(i.language, "TypeScript", "app.ts language")) |e| return e;
        if (expectEq(i.lsp_id, "typescript", "app.ts LSP languageId")) |e| return e;
        if (!i.grammar or !i.highlighted) return "app.ts is not highlighted by its grammar";
        if (expectEq(i.kind_at, "keyword", "app.ts kind of `interface`")) |e| return e;
        const in_str = std.mem.indexOf(u8, TS_SRC, "[)").?;
        const s = ctx.info(pane, in_str) orelse return "editor-lang at the TS string failed";
        if (s.pair_open) |po| {
            if (po == in_str) return "app.ts: a bracket inside a string matched (tree path)";
        }
        const body = std.mem.indexOf(u8, TS_SRC, "{ return").?;
        const b = ctx.info(pane, body) orelse return "editor-lang at the TS body failed";
        if (b.pair_open != body or b.pair_close != std.mem.lastIndexOfScalar(u8, TS_SRC, '}').?)
            return "app.ts: the function body's braces did not pair";
        if (!ctx.focus(pane)) return "could not focus app.ts";
        app.pressKey(null, "ctrl+/") catch return "injecting Ctrl+/ failed";
        if (!ctx.waitTextPrefix(pane, "// interface P")) return "Ctrl+/ in app.ts did not write a `//` comment";
    }

    // ---- Ruby (no grammar): the lexical rules still skip the string
    {
        const pane = ctx.open(rb) orelse return "new-editor-tab for notes.rb failed";
        const i = ctx.waitInfo(pane, null) orelse return "notes.rb never finished loading";
        if (expectEq(i.language, "Ruby", "notes.rb language")) |e| return e;
        if (i.grammar) return "Ruby unexpectedly has a grammar; this stage needs a grammar-less language";
        if (expectEq(i.comment_open, "#", "Ruby comment token")) |e| return e;
        const open_paren = std.mem.indexOfScalar(u8, RB_SRC, '(').?;
        const close_paren = std.mem.indexOf(u8, RB_SRC, ") #").?;
        const p = ctx.info(pane, open_paren) orelse return "editor-lang at puts( failed";
        if (p.pair_open != open_paren or p.pair_close != close_paren)
            return "notes.rb: puts( paired with a bracket inside a string or comment (lexical path)";
        const in_str = std.mem.indexOf(u8, RB_SRC, "\"(\"").? + 1;
        const s = ctx.info(pane, in_str) orelse return "editor-lang at the Ruby string failed";
        if (s.pair_open) |po| {
            if (po == in_str) return "notes.rb: a bracket inside a string matched (lexical path)";
        }
    }

    // ---- .editorconfig beats the content; the palette beats both
    {
        const pane = ctx.open(ec_py) orelse return "new-editor-tab for tabbed.py failed";
        const i = ctx.waitInfo(pane, null) orelse return "tabbed.py never finished loading";
        if (expectEq(i.indent_style, "spaces", "tabbed.py indent style")) |e| return e;
        if (expectEq(i.indent_source, "editorconfig", "tabbed.py indent source")) |e| return e;
        if (i.indent_size != 2) return "tabbed.py did not take indent_size = 2 from .editorconfig";
        if (std.mem.indexOf(u8, i.status, "Spaces: 2 (.editorconfig)") == null) {
            std.debug.print("smoke-e2e editor-lang: status '{s}'\n", .{i.status});
            return "the status line does not credit .editorconfig";
        }
        if (!ctx.focus(pane)) return "could not focus tabbed.py";
        app.pressKey(null, "tab") catch return "injecting Tab failed";
        if (!ctx.waitTextPrefix(pane, "  def f():")) return "Tab under .editorconfig did not insert two spaces";

        // Palette: "Indent Using Tabs" is a per-tab override.
        if (paletteRun(&ctx, "Indent Using Tabs")) |why| return why;
        var waited: u32 = 0;
        var ok = false;
        while (waited < 10_000) : (waited += 100) {
            if (ctx.info(pane, null)) |j| {
                if (std.mem.eql(u8, j.indent_style, "tabs") and std.mem.eql(u8, j.indent_source, "override")) {
                    ok = true;
                    break;
                }
            }
            _ = app.pumpOnce(100);
        }
        if (!ok) {
            const j = ctx.info(pane, null) orelse Info{};
            std.debug.print("smoke-e2e editor-lang: after the palette: {s} {d} ({s}), status '{s}'\n", .{ j.indent_style, j.indent_size, j.indent_source, j.status });
            return "the palette's Indent Using Tabs did not override the tab's indentation";
        }
    }
    return null;
}

/// Run one command from the command palette by typing its label.
fn paletteRun(ctx: *Ctx, label: []const u8) ?[]const u8 {
    const app = ctx.app;
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = rigwin.mainWin(app).id;
    var ref = app.frameRef(win_id, true) orelse return "no baseline frame for the palette";
    defer ref.deinit(ctx.allocator);
    // The chord a user presses, from the focused editor canvas.
    app.pressKey(null, "ctrl+shift+p") catch return "injecting ctrl+shift+p failed";
    if (!app.waitChangeSince(win_id, &ref, 15_000, 0.01, null)) return "ctrl+shift+p did not open the command palette";
    return paletteQuery(ctx.allocator, app, null, win_id, label);
}

/// Type `label` into the command palette open in `win_id`, wait until
/// the list is FILTERED to it, and press Return. `kbd` is the keyboard
/// target (null = the seat's current one). Shared by every stage that
/// drives the palette, so the waits below exist once.
pub fn paletteQuery(allocator: std.mem.Allocator, app: *appdrive.App, kbd: ?u32, win_id: u32, label: []const u8) ?[]const u8 {
    // Let the present fade finish first, or it passes for typed text.
    _ = app.waitVisualSettle(win_id, 600, 8_000, 0.0005, null);
    var ref2 = app.frameRef(win_id, true) orelse return "no pre-typing palette frame";
    defer ref2.deinit(allocator);
    // Wait for the FILTERED list, not the echoed text: GtkSearchEntry
    // runs the search after a delay, and a Return before it lands runs
    // the unfiltered top row. Emptying all but one of the visible rows
    // repaints several percent of the window; the echoed query alone is
    // a fraction of one.
    const FILTERED: f64 = 1.0;
    app.typeText(kbd, label) catch {};
    var filtered = app.waitChangeSince(win_id, &ref2, 8_000, FILTERED, null);
    if (!filtered) {
        // GTK's wayland IM module can leave a GtkText waiting for an
        // IME that this harness does not play; a paste bypasses it.
        app.pasteText(kbd, label) catch return "pasting the palette query failed";
        filtered = app.waitChangeSince(win_id, &ref2, 8_000, FILTERED, null);
    }
    if (!filtered) return "the palette never filtered down to the typed query";
    // The first partial query already filters; give the search delay
    // and the final ranking time to land (a quiet second, then one more
    // committed frame) so Return takes the row the whole query ranks.
    _ = app.waitVisualSettle(win_id, 1_000, 8_000, 0.002, null);
    _ = app.waitFrameAfter(win_id, app.frameCount(win_id), 3_000);
    app.pressKey(kbd, "return") catch return "injecting return into the palette failed";
    _ = app.waitIdle(300, 5_000);
    return null;
}

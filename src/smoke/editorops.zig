//! smoke-e2e stage: editor operations a user reaches only through the
//! keyboard, driven through the real seat and verified by reading the
//! document back (`get-text`).
//!
//! Covered: a command REBOUND in config.conf (`editor_keybind.join_lines
//! = <Control><Alt>j`, written by the rig) runs on its new chord and no
//! longer on its default; the find bar's Replace All (Ctrl+H, Tab to the
//! replace entry, Ctrl+Alt+Enter) is one undo step; Go to Line (Ctrl+G)
//! puts the caret on the line typed; a fold (Ctrl+Shift+[) is stepped
//! over by Down; and a project Replace (Ctrl+Shift+H, preview, Ctrl+Enter)
//! edits BUFFERS, open and unopened files alike, writing nothing to disk
//! until Save All.

const std = @import("std");
const c = @import("../c.zig").c;
const appdrive = @import("../ipc/appdrive.zig");
const el = @import("editorlang.zig");

/// What the rig writes into config.conf for this stage.
pub const CONFIG_LINE = "editor_keybind.join_lines = <Control><Alt>j\n";

/// Poll until the document is exactly `want`.
fn waitText(ctx: *el.Ctx, pane: u32, want: []const u8, what: []const u8) ?[]const u8 {
    var waited: u32 = 0;
    var last: []const u8 = "";
    while (waited < 10_000) : (waited += 100) {
        if (ctx.text(pane)) |t| {
            if (std.mem.eql(u8, t, want)) return null;
            last = t;
        }
        _ = ctx.app.pumpOnce(100);
    }
    std.debug.print("smoke-e2e editor-ops: {s}: document is '{s}', want '{s}'\n", .{ what, last, want });
    return what;
}

fn key(app: *appdrive.App, spec: []const u8) ?[]const u8 {
    app.pressKey(null, spec) catch return "injecting a key failed";
    _ = app.waitIdle(200, 3_000);
    return null;
}

fn typed(app: *appdrive.App, text: []const u8) ?[]const u8 {
    app.typeText(null, text) catch return "typing failed";
    _ = app.waitIdle(200, 3_000);
    return null;
}

/// Pump the session for `ms` of wall time.
fn pumpWall(app: *appdrive.App, ms: i64) void {
    const clock = @import("../util/clock.zig");
    const until = clock.nowMs() + ms;
    while (clock.nowMs() < until) _ = app.pumpOnce(50);
}

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zbuf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return null;
    const fp = c.fopen(z.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var buf: [4096]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, fp);
    return a.dupe(u8, buf[0..n]) catch null;
}

/// Poll until the file on disk reads exactly `want`.
fn waitDisk(ctx: *el.Ctx, path: []const u8, want: []const u8, what: []const u8) ?[]const u8 {
    var waited: u32 = 0;
    var last: []const u8 = "";
    while (waited < 10_000) : (waited += 100) {
        if (readFile(ctx.a(), path)) |t| {
            if (std.mem.eql(u8, t, want)) return null;
            last = t;
        }
        _ = ctx.app.pumpOnce(100);
    }
    std.debug.print("smoke-e2e editor-ops: {s}: disk has '{s}', want '{s}'\n", .{ what, last, want });
    return what;
}

pub fn stage(allocator: std.mem.Allocator, app: *appdrive.App, sock: [:0]const u8, rt: []const u8) ?[]const u8 {
    var ctx = el.Ctx{ .allocator = allocator, .app = app, .sock = sock, .arena = std.heap.ArenaAllocator.init(allocator) };
    defer ctx.arena.deinit();
    defer ctx.panes.deinit(allocator);
    defer ctx.closeAll();
    const a = ctx.a();

    const dir = std.fmt.allocPrint(a, "{s}/edops", .{rt}) catch return "fmt";
    el.mkdir(dir);
    const join = std.fmt.allocPrint(a, "{s}/join.txt", .{dir}) catch return "fmt";
    const find = std.fmt.allocPrint(a, "{s}/find.txt", .{dir}) catch return "fmt";
    const goto = std.fmt.allocPrint(a, "{s}/goto.txt", .{dir}) catch return "fmt";
    const fold = std.fmt.allocPrint(a, "{s}/fold.py", .{dir}) catch return "fmt";
    if (!el.writeFile(join, "a\nb\n") or !el.writeFile(find, "foo x foo y foo\n") or
        !el.writeFile(goto, "l1\nl2\nl3\nl4\n") or !el.writeFile(fold, "def f():\n    a = 1\n    b = 2\nc = 3\n"))
        return "could not write the editor-ops fixtures";

    // ---- a command rebound in config.conf
    {
        const pane = ctx.open(join) orelse return "new-editor-tab for join.txt failed";
        _ = ctx.waitInfo(pane, 0) orelse return "join.txt never finished loading";
        if (!ctx.focus(pane)) return "could not focus join.txt";
        if (key(app, "ctrl+alt+j")) |e| return e;
        if (waitText(&ctx, pane, "a b\n", "the rebound chord Ctrl+Alt+J did not join the lines")) |e| return e;
        // The override replaced the default: Ctrl+J must not join the
        // remaining newline away.
        if (key(app, "ctrl+j")) |e| return e;
        _ = app.waitIdle(300, 2_000);
        if (waitText(&ctx, pane, "a b\n", "the default Ctrl+J still ran join_lines after the override")) |e| return e;
    }

    // ---- find bar: Replace All, one undo step
    {
        const pane = ctx.open(find) orelse return "new-editor-tab for find.txt failed";
        _ = ctx.waitInfo(pane, 0) orelse return "find.txt never finished loading";
        if (!ctx.focus(pane)) return "could not focus find.txt";
        if (key(app, "ctrl+h")) |e| return e;
        if (typed(app, "foo")) |e| return e;
        if (key(app, "tab")) |e| return e;
        if (typed(app, "bar")) |e| return e;
        if (key(app, "ctrl+alt+return")) |e| return e;
        if (waitText(&ctx, pane, "bar x bar y bar\n", "Ctrl+Alt+Enter in the find bar did not replace every match")) |e| return e;
        if (key(app, "escape")) |e| return e;
        if (key(app, "ctrl+z")) |e| return e;
        if (waitText(&ctx, pane, "foo x foo y foo\n", "one Ctrl+Z did not undo the whole Replace All")) |e| return e;
    }

    // ---- Go to Line
    {
        const pane = ctx.open(goto) orelse return "new-editor-tab for goto.txt failed";
        _ = ctx.waitInfo(pane, 0) orelse return "goto.txt never finished loading";
        if (!ctx.focus(pane)) return "could not focus goto.txt";
        if (key(app, "ctrl+g")) |e| return e;
        _ = app.waitIdle(300, 3_000);
        if (typed(app, "3")) |e| return e;
        if (key(app, "return")) |e| return e;
        if (typed(app, "X")) |e| return e;
        if (waitText(&ctx, pane, "l1\nl2\nXl3\nl4\n", "Ctrl+G 3 did not put the caret on line 3")) |e| return e;
    }

    // ---- a fold is stepped over
    {
        const pane = ctx.open(fold) orelse return "new-editor-tab for fold.py failed";
        _ = ctx.waitInfo(pane, 0) orelse return "fold.py never finished loading";
        if (!ctx.focus(pane)) return "could not focus fold.py";
        if (key(app, "ctrl+shift+[")) |e| return e;
        if (key(app, "down")) |e| return e;
        if (typed(app, "X")) |e| return e;
        if (waitText(&ctx, pane, "def f():\n    a = 1\n    b = 2\nXc = 3\n", "Down after Ctrl+Shift+[ did not step over the folded body")) |e| return e;
    }

    // ---- project Replace: buffers only, until Save All
    {
        const proj = std.fmt.allocPrint(a, "{s}/edproj", .{rt}) catch return "fmt";
        el.mkdir(proj);
        const marker = std.fmt.allocPrint(a, "{s}/.sketerm-project", .{proj}) catch return "fmt";
        const pa = std.fmt.allocPrint(a, "{s}/a.txt", .{proj}) catch return "fmt";
        const pb = std.fmt.allocPrint(a, "{s}/b.txt", .{proj}) catch return "fmt";
        if (!el.writeFile(marker, "") or !el.writeFile(pa, "NEEDLE one\n") or !el.writeFile(pb, "NEEDLE two\n"))
            return "could not write the project-replace fixtures";
        const pane = ctx.open(pa) orelse return "new-editor-tab for a.txt failed";
        _ = ctx.waitInfo(pane, 0) orelse return "a.txt never finished loading";
        if (!ctx.focus(pane)) return "could not focus a.txt";
        if (key(app, "ctrl+shift+h")) |e| return e;
        if (typed(app, "NEEDLE")) |e| return e;
        // Again, with a needle typed: focus moves to the replacement.
        if (key(app, "ctrl+shift+h")) |e| return e;
        if (typed(app, "PIN")) |e| return e;
        if (key(app, "return")) |e| return e; // preview
        // The preview is a daemon search job; give it wall time.
        pumpWall(app, 3_000);
        if (key(app, "ctrl+return")) |e| return e; // apply
        _ = app.waitIdle(500, 5_000);
        // Nothing reached the disk: the change is in buffers.
        if (waitDisk(&ctx, pa, "NEEDLE one\n", "project replace wrote the open file behind the user's back")) |e| return e;
        if (waitDisk(&ctx, pb, "NEEDLE two\n", "project replace wrote the unopened file behind the user's back")) |e| return e;
        if (key(app, "escape")) |e| return e;
        if (key(app, "ctrl+alt+s")) |e| return e; // Save All
        if (waitDisk(&ctx, pa, "PIN one\n", "Save All after a project replace did not write the open file")) |e| return e;
        if (waitDisk(&ctx, pb, "PIN two\n", "Save All after a project replace did not write the file it opened")) |e| return e;
    }
    return null;
}

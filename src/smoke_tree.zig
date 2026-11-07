//! smoke-tree: expanding and collapsing directory rows in a scrolled
//! details listing keeps the scroll offset, the rows on screen and the
//! keyboard cursor, on the REAL GUI and sketerm's own compositor
//! (CLAUDE.md "Headless GUI testing"; never X).
//!
//! The rig scrolls a large folder down, then expands directories by
//! clicking their chevron and by the Right key: the scroll offset and
//! the expanded row's on-screen position must not move, only the rows
//! that actually changed may rebind, and the next Up/Down must step
//! from the expanded row rather than from the top of the listing.
//! Collapse (click and Left), a nested expand, an empty directory and a
//! descending sort are covered the same way. Every step is read back
//! through the `browser-rows` verification command.
//!
//! Screenshots land in zig-out/smoke-tree-*.png. Everything created here
//! is destroyed by exact pid / session name.

const std = @import("std");
const bindir = @import("smoke/bindir.zig");
const c = @import("c.zig").c;
const unsetEnv = @import("util/env.zig").unset;
const platform = @import("util/platform.zig");
const appdrive = @import("ipc/appdrive.zig");
const clock = @import("util/clock.zig");
const smokecli = @import("smoke/displaycli.zig");
const ctlsock = @import("smoke/ctlsock.zig");

const TTL = "180";
const SESSION = "treesmoke";
/// Directories `d-000`..; `NNN % 4` decides the contents: 0 empty,
/// 1 one file, 2 a file plus a nested `inner` directory, 3 three files.
const DIRS = 80;
const FILES = 40;
/// Most name cells one expand or collapse may bind: the changed row,
/// the inserted children and a little slack for GTK's prerendered
/// rows. A rebuilt viewport binds every visible row (~30 here).
const MAX_BINDS = 8;

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var g_gui_sock: [:0]const u8 = "";
var g_win: u32 = 0;
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-tree: " ++ fmt ++ "\n", args, 0) catch return;
    _ = c.fprintf(platform.stdout(), "%s", s.ptr);
    _ = c.fflush(platform.stdout());
}

fn teardown() void {
    if (drive) |app| {
        app.detach();
        drive = null;
    }
    if (child_pid > 0) {
        _ = c.kill(child_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(child_pid, &status, 0);
        child_pid = 0;
    }
    if (display_ready and g_mux_sock.len > 0) {
        const r = smokecli.runDisplayCli(g_alloc, &.{ "destroy", SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        _ = c.kill(daemon_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(daemon_pid, &status, 0);
        daemon_pid = 0;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-tree: FAIL - " ++ fmt ++ "\n", args, 0) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < ms) _ = app.pumpOnce(20);
}

fn savePng(app: *appdrive.App, stem: []const u8) void {
    const png = app.screenshotPng(g_win, 1600, null, 0) catch return;
    defer g_alloc.free(png.png);
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "zig-out/smoke-tree-{s}.png", .{stem}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(png.png.ptr, 1, png.png.len, f);
}

const Row = struct {
    path: []const u8,
    pos: u32,
    depth: u32,
    expanded: bool,
    y: f64,
    expander_x: f64,
    expander_y: f64,
    label_x: f64,
    alt: bool = false,
};
const Listing = struct {
    scroll: f64 = 0,
    upper: f64 = 0,
    page: f64 = 0,
    n_items: u32 = 0,
    focus: i64 = -1,
    focus_path: []const u8 = "",
    binds: u64 = 0,
    unmapped: u32 = 0,
    selected: []const []const u8 = &.{},
    rows: []Row = &.{},
};
const Reply = struct { ok: bool = false, listing: Listing = .{} };
const Snap = std.json.Parsed(Reply);

fn rows(app: *appdrive.App, label: []const u8) ?Snap {
    const reply = ctlsock.roundtrip(g_alloc, app, g_gui_sock, "{\"cmd\":\"browser-rows\",\"pane\":1}\n") orelse return null;
    defer g_alloc.free(reply);
    const parsed = std.json.parseFromSlice(Reply, g_alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        say("browser-rows reply: {s}", .{reply[0..@min(reply.len, 600)]});
        return null;
    };
    if (!parsed.value.ok or parsed.value.listing.rows.len == 0) {
        say("browser-rows reply: {s}", .{reply[0..@min(reply.len, 600)]});
        parsed.deinit();
        return null;
    }
    const l = parsed.value.listing;
    say("{s}: scroll {d:.0}/{d:.0}, {d} items, {d} rows visible ({s} .. {s}), focus {d} {s}, selected {d}{s}{s}, binds {d}, unmapped {d}", .{
        label,                                          l.scroll, l.upper, l.n_items, l.rows.len,
        std.fs.path.basename(l.rows[0].path),           std.fs.path.basename(l.rows[l.rows.len - 1].path),
        l.focus,                                        std.fs.path.basename(l.focus_path),    l.selected.len,
        if (l.selected.len > 0) " " else "",            if (l.selected.len > 0) std.fs.path.basename(l.selected[0]) else "",
        l.binds,                                        l.unmapped,
    });
    return parsed;
}

fn findRow(l: Listing, path: []const u8) ?Row {
    for (l.rows) |r| if (std.mem.eql(u8, r.path, path)) return r;
    return null;
}

fn rowAt(l: Listing, pos: u32) ?Row {
    for (l.rows) |r| if (r.pos == pos) return r;
    return null;
}

/// A collapsed top-level `d-NNN` with `NNN % 4 == kind`, in the middle
/// of the visible rows so its children land on screen.
fn pickDir(l: Listing, kind: u32, path_buf: []u8) ?[]const u8 {
    const lo = l.rows.len / 4;
    const hi = l.rows.len / 2 + 2;
    for (l.rows[lo..@min(hi, l.rows.len)]) |r| {
        if (r.depth != 0 or r.expanded or r.expander_x == 0) continue;
        const base = std.fs.path.basename(r.path);
        if (base.len != 5 or !std.mem.startsWith(u8, base, "d-")) continue;
        const n = std.fmt.parseInt(u32, base[2..], 10) catch continue;
        if (n % 4 != kind) continue;
        if (r.path.len > path_buf.len) return null;
        @memcpy(path_buf[0..r.path.len], r.path);
        return path_buf[0..r.path.len];
    }
    return null;
}

var why_buf: [512]u8 = undefined;

/// Null when expanding/collapsing `path` left the viewport where it
/// was; otherwise what moved.
fn stable(before: Listing, after: Listing, path: []const u8) ?[]const u8 {
    if (@abs(after.scroll - before.scroll) > 1)
        return std.fmt.bufPrint(&why_buf, "the scroll offset moved from {d:.0} to {d:.0}", .{ before.scroll, after.scroll }) catch "scroll moved";
    const b = findRow(before, path) orelse return "the row was not on screen before";
    const a = findRow(after, path) orelse return "the row is no longer on screen";
    if (@abs(a.y - b.y) > 1)
        return std.fmt.bufPrint(&why_buf, "the row moved on screen from y={d:.0} to y={d:.0}", .{ b.y, a.y }) catch "row moved";
    if (after.binds - before.binds > MAX_BINDS)
        return std.fmt.bufPrint(&why_buf, "{d} name cells rebound (at most {d} may)", .{ after.binds - before.binds, MAX_BINDS }) catch "rebound";
    // Kept rows must still be reachable by path (thumbnails, inline
    // rename): a splice that keeps a row also keeps its map entry.
    if (after.unmapped != 0)
        return std.fmt.bufPrint(&why_buf, "{d} visible rows lost their path -> name cell entry", .{after.unmapped}) catch "unmapped";
    return stripes(after);
}

/// Null when adjacent rows alternate their zebra stripe.
fn stripes(l: Listing) ?[]const u8 {
    for (l.rows[0 .. l.rows.len - 1], l.rows[1..]) |a, b| {
        if (a.pos + 1 != b.pos or a.alt != b.alt) continue;
        return std.fmt.bufPrint(&why_buf, "rows {d} ({s}) and {d} ({s}) carry the same zebra stripe", .{
            a.pos, std.fs.path.basename(a.path), b.pos, std.fs.path.basename(b.path),
        }) catch "zebra out of phase";
    }
    return null;
}

/// Expand a directory with Right, step Down onto its first child, then
/// collapse the directory by its chevron: the cursor's row is gone, so
/// the cursor lands on the directory and Down moves on from there.
fn collapseUnderStage(app: *appdrive.App) ?[]const u8 {
    const s0 = rows(app, "collapse under the cursor") orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, 3, &pb) orelse return "no suitable directory on screen";
    const t = findRow(s0.value.listing, path).?;
    say("collapse under the cursor: {s}, Right, Down, chevron", .{std.fs.path.basename(path)});
    app.click(g_win, t.label_x, t.y, 1) catch return "click failed";
    pumpFor(app, 600);
    const s1 = key(app, "Right", EXPAND_MS, "  Right") orelse return "no rows after Right";
    defer s1.deinit();
    const s2 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s2.deinit();
    const t2 = findRow(s2.value.listing, path) orelse return "the directory left the screen";
    const child = rowAt(s2.value.listing, t2.pos + 1) orelse return "no child row";
    if (cursorOn(s2.value.listing, child.path)) |why| return why;
    app.click(g_win, t2.expander_x, t2.expander_y, 1) catch return "click failed";
    pumpFor(app, 800);
    const s3 = rows(app, "  collapsed") orelse return "no rows after collapse";
    defer s3.deinit();
    if (stable(s2.value.listing, s3.value.listing, path)) |why| return why;
    const t3 = findRow(s3.value.listing, path).?;
    if (t3.expanded) return "the directory did not collapse";
    if (!std.mem.eql(u8, s3.value.listing.focus_path, path))
        return std.fmt.bufPrint(&why_buf, "keyboard focus is on '{s}' (row {d}), not the collapsed directory", .{ s3.value.listing.focus_path, s3.value.listing.focus }) catch "focus elsewhere";
    const next = rowAt(s3.value.listing, t3.pos + 1) orelse return "no row below";
    var next_buf: [512]u8 = undefined;
    const next_path = next_buf[0..next.path.len];
    @memcpy(next_path, next.path);
    // The hidden child stays selected (a collapse is not a deletion),
    // so GTK's first Down selects the unselected cursor row in place,
    // and the second one moves on.
    const s4 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s4.deinit();
    if (cursorOn(s4.value.listing, path)) |why| return why;
    if (@abs(s4.value.listing.scroll - s3.value.listing.scroll) > 1) return "Down scrolled the listing";
    const s5 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s5.deinit();
    if (cursorOn(s5.value.listing, next_path)) |why| return why;
    return null;
}

/// With the cursor on a row BELOW a one-child directory, click that
/// directory's chevron: every row after it shifts down one and flips
/// its zebra parity, yet none may rebind, lose its stripe phase or
/// take the cursor with it.
fn aboveStage(app: *appdrive.App) ?[]const u8 {
    const s0 = rows(app, "cursor below") orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, 1, &pb) orelse return "no suitable directory on screen";
    const d = findRow(s0.value.listing, path).?;
    const r = rowAt(s0.value.listing, d.pos + 3) orelse return "no row three below";
    var r_buf: [512]u8 = undefined;
    const r_path = r_buf[0..r.path.len];
    @memcpy(r_path, r.path);
    say("cursor below: selecting {s}, then clicking the chevron of {s}", .{ std.fs.path.basename(r_path), std.fs.path.basename(path) });
    app.click(g_win, r.label_x, r.y, 1) catch return "click failed";
    pumpFor(app, 600);
    const s1 = rows(app, "  selected") orelse return "no rows after select";
    defer s1.deinit();
    if (cursorOn(s1.value.listing, r_path)) |why| return why;
    app.click(g_win, d.expander_x, d.expander_y, 1) catch return "click failed";
    pumpFor(app, EXPAND_MS);
    const s2 = rows(app, "  expanded above") orelse return "no rows after expand";
    defer s2.deinit();
    savePng(app, "above-expanded");
    if (stable(s1.value.listing, s2.value.listing, path)) |why| return why;
    if (s2.value.listing.n_items != s1.value.listing.n_items + 1) return "the child was not inserted";
    if (cursorOn(s2.value.listing, r_path)) |why| return why;
    const r2 = findRow(s2.value.listing, r_path) orelse return "the cursor row left the screen";
    const next = rowAt(s2.value.listing, r2.pos + 1) orelse return "no row below the cursor";
    var next_buf: [512]u8 = undefined;
    const next_path = next_buf[0..next.path.len];
    @memcpy(next_path, next.path);
    const s3 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s3.deinit();
    if (cursorOn(s3.value.listing, next_path)) |why| return why;
    const d3 = findRow(s3.value.listing, path) orelse return "the directory left the screen";
    app.click(g_win, d3.expander_x, d3.expander_y, 1) catch return "click failed";
    pumpFor(app, 800);
    const s4 = rows(app, "  collapsed above") orelse return "no rows after collapse";
    defer s4.deinit();
    if (stable(s3.value.listing, s4.value.listing, path)) |why| return why;
    if (cursorOn(s4.value.listing, next_path)) |why| return why;
    return null;
}

/// Null when keyboard focus and the (single) selection are on `path`.
fn cursorOn(l: Listing, path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, l.focus_path, path))
        return std.fmt.bufPrint(&why_buf, "keyboard focus is on '{s}' (row {d}), not '{s}'", .{ l.focus_path, l.focus, path }) catch "focus elsewhere";
    if (l.selected.len != 1 or !std.mem.eql(u8, l.selected[0], path))
        return std.fmt.bufPrint(&why_buf, "the selection is {d} rows ('{s}'), not '{s}'", .{ l.selected.len, if (l.selected.len > 0) l.selected[0] else "", path }) catch "selection elsewhere";
    return null;
}

/// Press `key` and return the snapshot after it settled.
fn key(app: *appdrive.App, spec: []const u8, settle_ms: i64, label: []const u8) ?Snap {
    app.pressKey(g_win, spec) catch return null;
    pumpFor(app, settle_ms);
    return rows(app, label);
}

const EXPAND_MS = 1500;

/// Click-expand then click-collapse a directory of `kind`.
fn clickStage(app: *appdrive.App, kind: u32, children: u32, label: []const u8) ?[]const u8 {
    const s0 = rows(app, label) orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, kind, &pb) orelse return "no suitable directory on screen";
    const t = findRow(s0.value.listing, path).?;
    say("{s}: clicking the chevron of {s}", .{ label, std.fs.path.basename(path) });
    app.click(g_win, t.expander_x, t.expander_y, 1) catch return "click failed";
    pumpFor(app, EXPAND_MS);
    const s1 = rows(app, "  expanded") orelse return "no rows after expand";
    defer s1.deinit();
    savePng(app, "click-expanded");
    if (stable(s0.value.listing, s1.value.listing, path)) |why| return why;
    const t1 = findRow(s1.value.listing, path).?;
    if (!t1.expanded) return "the directory did not expand";
    if (s1.value.listing.n_items != s0.value.listing.n_items + children) return "the children were not inserted";
    app.click(g_win, t1.expander_x, t1.expander_y, 1) catch return "click failed";
    pumpFor(app, 800);
    const s2 = rows(app, "  collapsed") orelse return "no rows after collapse";
    defer s2.deinit();
    if (stable(s1.value.listing, s2.value.listing, path)) |why| return why;
    if (findRow(s2.value.listing, path).?.expanded) return "the directory did not collapse";
    if (s2.value.listing.n_items != s0.value.listing.n_items) return "the children were not removed";
    return null;
}

/// Select a directory of `kind` by clicking it, expand it with Right,
/// step Down into it and Up back, collapse it with Left and step Down
/// to its next sibling.
fn keyStage(app: *appdrive.App, kind: u32, children: u32, label: []const u8) ?[]const u8 {
    const s0 = rows(app, label) orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, kind, &pb) orelse return "no suitable directory on screen";
    const t = findRow(s0.value.listing, path).?;
    say("{s}: selecting {s}, then Right", .{ label, std.fs.path.basename(path) });
    app.click(g_win, t.label_x, t.y, 1) catch return "click failed";
    pumpFor(app, 600);
    const s1 = rows(app, "  selected") orelse return "no rows after select";
    defer s1.deinit();
    if (cursorOn(s1.value.listing, path)) |why| return why;

    const s2 = key(app, "Right", EXPAND_MS, "  Right") orelse return "no rows after Right";
    defer s2.deinit();
    savePng(app, "key-expanded");
    if (stable(s1.value.listing, s2.value.listing, path)) |why| return why;
    const t2 = findRow(s2.value.listing, path).?;
    if (!t2.expanded) return "Right did not expand the directory";
    if (s2.value.listing.n_items != s1.value.listing.n_items + children) return "the children were not inserted";
    if (cursorOn(s2.value.listing, path)) |why| return why;

    const below = rowAt(s2.value.listing, t2.pos + 1) orelse return "no row below the expanded one";
    var below_buf: [512]u8 = undefined;
    const below_path = below_buf[0..below.path.len];
    @memcpy(below_path, below.path);
    const s3 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s3.deinit();
    if (cursorOn(s3.value.listing, below_path)) |why| return why;
    const s4 = key(app, "Up", 500, "  Up") orelse return "no rows after Up";
    defer s4.deinit();
    if (cursorOn(s4.value.listing, path)) |why| return why;

    const s5 = key(app, "Left", 800, "  Left") orelse return "no rows after Left";
    defer s5.deinit();
    if (stable(s4.value.listing, s5.value.listing, path)) |why| return why;
    const t5 = findRow(s5.value.listing, path).?;
    if (t5.expanded) return "Left did not collapse the directory";
    if (cursorOn(s5.value.listing, path)) |why| return why;
    const next = rowAt(s5.value.listing, t5.pos + 1) orelse return "no row below the collapsed one";
    var next_buf: [512]u8 = undefined;
    const next_path = next_buf[0..next.path.len];
    @memcpy(next_path, next.path);
    const s6 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s6.deinit();
    if (cursorOn(s6.value.listing, next_path)) |why| return why;
    return null;
}

/// Expand a `kind 2` directory with Right, walk Down to its `inner`
/// subdirectory, expand that too and step Down into it.
fn nestedStage(app: *appdrive.App) ?[]const u8 {
    const s0 = rows(app, "nested") orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, 2, &pb) orelse return "no suitable directory on screen";
    const t = findRow(s0.value.listing, path).?;
    say("nested: selecting {s}, Right, down to inner, Right", .{std.fs.path.basename(path)});
    app.click(g_win, t.label_x, t.y, 1) catch return "click failed";
    pumpFor(app, 600);
    const s1 = key(app, "Right", EXPAND_MS, "  Right") orelse return "no rows after Right";
    defer s1.deinit();
    if (stable(s0.value.listing, s1.value.listing, path)) |why| return why;
    var inner_buf: [600]u8 = undefined;
    const inner = std.fmt.bufPrint(&inner_buf, "{s}/inner", .{path}) catch return "path";
    var steps: u32 = 0;
    var cur = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    while (!std.mem.eql(u8, cur.value.listing.focus_path, inner)) {
        steps += 1;
        if (steps > 2) {
            cur.deinit();
            return "Down never reached the inner directory";
        }
        cur.deinit();
        cur = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    }
    defer cur.deinit();
    if (cursorOn(cur.value.listing, inner)) |why| return why;
    const s2 = key(app, "Right", EXPAND_MS, "  Right (inner)") orelse return "no rows after Right";
    defer s2.deinit();
    if (stable(cur.value.listing, s2.value.listing, inner)) |why| return why;
    const ti = findRow(s2.value.listing, inner).?;
    if (!ti.expanded) return "Right did not expand the inner directory";
    if (cursorOn(s2.value.listing, inner)) |why| return why;
    const deep = rowAt(s2.value.listing, ti.pos + 1) orelse return "no row below inner";
    if (deep.depth != 2) return "the row below inner is not its child";
    var deep_buf: [600]u8 = undefined;
    const deep_path = deep_buf[0..deep.path.len];
    @memcpy(deep_path, deep.path);
    const s3 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s3.deinit();
    if (cursorOn(s3.value.listing, deep_path)) |why| return why;
    return null;
}

/// Right on an empty directory: nothing inserted, nothing moves, and
/// Down reaches the next sibling.
fn emptyStage(app: *appdrive.App) ?[]const u8 {
    const s0 = rows(app, "empty") orelse return "no rows";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickDir(s0.value.listing, 0, &pb) orelse return "no suitable directory on screen";
    const t = findRow(s0.value.listing, path).?;
    say("empty: selecting {s}, then Right", .{std.fs.path.basename(path)});
    app.click(g_win, t.label_x, t.y, 1) catch return "click failed";
    pumpFor(app, 600);
    const s1 = rows(app, "  selected") orelse return "no rows after select";
    defer s1.deinit();
    const s2 = key(app, "Right", EXPAND_MS, "  Right") orelse return "no rows after Right";
    defer s2.deinit();
    if (stable(s1.value.listing, s2.value.listing, path)) |why| return why;
    if (s2.value.listing.n_items != s1.value.listing.n_items) return "rows appeared under an empty directory";
    if (cursorOn(s2.value.listing, path)) |why| return why;
    const t2 = findRow(s2.value.listing, path).?;
    const next = rowAt(s2.value.listing, t2.pos + 1) orelse return "no row below";
    var next_buf: [512]u8 = undefined;
    const next_path = next_buf[0..next.path.len];
    @memcpy(next_path, next.path);
    const s3 = key(app, "Down", 500, "  Down") orelse return "no rows after Down";
    defer s3.deinit();
    if (cursorOn(s3.value.listing, next_path)) |why| return why;
    return null;
}

fn scrollDown(app: *appdrive.App, x: f64, y: f64, min_scroll: f64) bool {
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        app.scroll(g_win, x, y, 0, 3) catch return false;
        pumpFor(app, 250);
        const s = rows(app, "scrolling") orelse return false;
        defer s.deinit();
        if (s.value.listing.scroll >= min_scroll) return true;
    }
    return false;
}

const ColReply = struct {
    ok: bool = false,
    listing: struct { columns: []struct { title: []const u8, x: f64, width: f64, y: f64 } = &.{} } = .{},
};

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    if (!bindir.init(init.args.vector)) return 1;
    g_alloc = allocator;

    if (platform.is_macos) {
        say("skipped (no Wayland display sessions on macOS)", .{});
        return 0;
    }
    if (!@import("util/lifetime.zig").arm()) return fail("lifetime fence", .{});

    // Short isolated runtime dir: a long socket path cannot bind and the
    // GUI would autostart the INSTALLED daemon (CLAUDE.md).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintSentinel(&rt_buf, "/tmp/skt-{d}", .{c.getpid()}, 0) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID" }) |name| _ = unsetEnv(name);
    defer @import("util/pathz.zig").removeTree(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig unless warmed.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // ── the folder ────────────────────────────────────────────────
    var files_buf: [160]u8 = undefined;
    const files_dir = std.fmt.bufPrintSentinel(&files_buf, "{s}/files", .{rt}, 0) catch return fail("files path", .{});
    _ = c.mkdir(files_dir.ptr, 0o755);
    {
        var i: u32 = 0;
        while (i < DIRS) : (i += 1) {
            var d_buf: [256]u8 = undefined;
            const d = std.fmt.bufPrintSentinel(&d_buf, "{s}/d-{d:0>3}", .{ files_dir, i }, 0) catch continue;
            _ = c.mkdir(d.ptr, 0o755);
            const files: u32 = switch (i % 4) {
                0 => 0,
                1, 2 => 1,
                else => 3,
            };
            var k: u32 = 0;
            while (k < files) : (k += 1) touch("{s}/c-{d}.txt", .{ d, k });
            if (i % 4 == 2) {
                var n_buf: [300]u8 = undefined;
                const n = std.fmt.bufPrintSentinel(&n_buf, "{s}/inner", .{d}, 0) catch continue;
                _ = c.mkdir(n.ptr, 0o755);
                k = 0;
                while (k < 3) : (k += 1) touch("{s}/deep-{d}.txt", .{ n, k });
            }
        }
        i = 0;
        while (i < FILES) : (i += 1) touch("{s}/f-{d:0>3}.txt", .{ files_dir, i });
    }

    // ── private daemon ────────────────────────────────────────────
    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork", .{});
    if (mux_pid == 0) {
        platform.dieWithParent();
        const argv = [_:null]?[*:0]const u8{ bindir.path(.@"sketerm-mux"), "--broker", null };
        _ = c.execv(bindir.path(.@"sketerm-mux"), @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var sock_buf: [256]u8 = undefined;
    const mux_sock = std.fmt.bufPrintSentinel(&sock_buf, "{s}/sketerm/mux.sock", .{rt}, 0) catch return fail("sock path", .{});
    var waited: u32 = 0;
    while (c.access(mux_sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(50_000);
        waited += 1;
        if (waited > 100) return fail("private mux socket never appeared", .{});
    }
    g_mux_sock = mux_sock;
    // Zebra stripes on: an odd number of inserted children flips the
    // parity of every row after them, the case most likely to rebind.
    {
        var pl_buf: [200]u8 = undefined;
        const pl = std.fmt.bufPrintSentinel(&pl_buf, "{s}/sketerm/places.json", .{rt}, 0) catch return fail("places path", .{});
        const f = c.fopen(pl.ptr, "wb") orelse return fail("writing places.json", .{});
        _ = c.fputs("{\"zebra\":true}\n", f);
        _ = c.fclose(f);
    }

    // ── display session + viewer (BEFORE the GUI) ─────────────────
    var wl_z: [4096:0]u8 = undefined;
    {
        const r = smokecli.runDisplayCli(allocator, &.{ "create", "--name", SESSION, "--ttl", TTL, "--size", "1600x1000", "--json", "--socket", mux_sock });
        defer allocator.free(r.out);
        if (r.code != 0) return fail("display create failed", .{});
        display_ready = true;
        var parsed = std.json.parseFromSlice(smokecli.CreateReply, allocator, r.out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return fail("display create JSON", .{});
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return fail("no absolute WAYLAND_DISPLAY", .{});
        _ = std.fmt.bufPrintSentinel(&wl_z, "{s}", .{wl}, 0) catch return fail("WAYLAND_DISPLAY too long", .{});
    }
    drive = appdrive.App.attachExisting(allocator, SESSION, null, mux_sock, null) catch
        return fail("could not attach a viewer", .{});
    const app = drive.?;

    // ── the GUI ───────────────────────────────────────────────────
    const pid = c.fork();
    if (pid < 0) return fail("fork", .{});
    if (pid == 0) {
        platform.dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.treesmoke", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = unsetEnv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        _ = c.setenv("SKETERM_WELCOME", "0", 1);
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        const argv = [_:null]?[*:0]const u8{ bindir.path(.sketerm), null };
        _ = c.execv(bindir.path(.sketerm), @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;
    if (!app.waitFirstWindow(60_000)) return fail("the GUI never committed a window", .{});
    for (app.windows.items) |w| if (!w.popup and w.w > 0) {
        g_win = w.id;
        break;
    };
    if (g_win == 0) return fail("no toplevel window", .{});
    var gui_buf: [256]u8 = undefined;
    g_gui_sock = std.fmt.bufPrintSentinel(&gui_buf, "{s}/sketerm/{d}.sock", .{ rt, child_pid }, 0) catch return fail("GUI socket path", .{});
    {
        const t0 = clock.nowMs();
        while (true) {
            pumpFor(app, 200);
            if (ctlsock.roundtrip(allocator, app, g_gui_sock, "{\"cmd\":\"list\"}\n")) |r| {
                defer allocator.free(r);
                if (std.mem.indexOf(u8, r, "\"ok\":true") != null) break;
            }
            if (clock.nowMs() - t0 > 30_000) return fail("the GUI control socket never answered", .{});
        }
    }
    app.resizeWindow(g_win, 1200, 700) catch return fail("sizing the window", .{});
    pumpFor(app, 1500);

    // ── the file view, scrolled down ──────────────────────────────
    {
        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":1,\"data\":\"{s}\"}}\n", .{files_dir}) catch return fail("browser-here format", .{});
        const r = ctlsock.roundtrip(allocator, app, g_gui_sock, req) orelse return fail("browser-here roundtrip", .{});
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"ok\":true") == null) return fail("browser-here refused: {s}", .{r});
    }
    pumpFor(app, 2500);
    var sx: f64 = 0;
    var sy: f64 = 0;
    {
        const s = rows(app, "initial") orelse return fail("no rows in the listing", .{});
        defer s.deinit();
        const l = s.value.listing;
        if (l.n_items < DIRS + FILES) return fail("only {d} rows listed", .{l.n_items});
        sx = l.rows[0].label_x + 40;
        sy = l.rows[l.rows.len / 2].y;
    }
    if (!scrollDown(app, sx, sy, 400)) return fail("could not scroll the listing down", .{});
    savePng(app, "1-scrolled");

    if (clickStage(app, 3, 3, "click, three children")) |why| return fail("click expand/collapse: {s} (zig-out/smoke-tree-click-expanded.png)", .{why});
    if (clickStage(app, 1, 1, "click, one child")) |why| return fail("click expand/collapse (odd count): {s}", .{why});
    if (keyStage(app, 3, 3, "keys, three children")) |why| return fail("Right/Down/Up/Left: {s} (zig-out/smoke-tree-key-expanded.png)", .{why});
    if (nestedStage(app)) |why| return fail("nested expand: {s}", .{why});
    if (emptyStage(app)) |why| return fail("empty directory: {s}", .{why});
    if (aboveStage(app)) |why| return fail("expand above the cursor: {s} (zig-out/smoke-tree-above-expanded.png)", .{why});
    if (collapseUnderStage(app)) |why| return fail("collapse under the cursor: {s}", .{why});

    // ── the same under a descending sort ──────────────────────────
    {
        const reply = ctlsock.roundtrip(allocator, app, g_gui_sock, "{\"cmd\":\"browser-columns\",\"pane\":1}\n") orelse return fail("browser-columns", .{});
        defer allocator.free(reply);
        const p = std.json.parseFromSlice(ColReply, allocator, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return fail("browser-columns JSON", .{});
        defer p.deinit();
        var clicked = false;
        for (p.value.listing.columns) |col| if (std.mem.eql(u8, col.title, "Name")) {
            say("sorting: clicking the Name header", .{});
            app.click(g_win, col.x + col.width / 2, col.y, 1) catch return fail("header click", .{});
            clicked = true;
            break;
        };
        if (!clicked) return fail("no Name column header", .{});
        pumpFor(app, 1200);
        const s = rows(app, "sorted") orelse return fail("no rows after sorting", .{});
        defer s.deinit();
        const l = s.value.listing;
        // Descending by name: any two adjacent top-level rows say so.
        var reversed = false;
        for (l.rows[0 .. l.rows.len - 1], l.rows[1..]) |a, b| {
            if (a.depth != 0 or b.depth != 0 or a.pos + 1 != b.pos) continue;
            reversed = std.mem.order(u8, std.fs.path.basename(a.path), std.fs.path.basename(b.path)) == .gt;
            break;
        }
        if (!reversed) return fail("the Name header did not reverse the sort", .{});
    }
    if (!scrollDown(app, sx, sy, 400)) return fail("could not scroll the sorted listing down", .{});
    if (keyStage(app, 1, 1, "sorted, keys")) |why| return fail("sorted Right/Down/Up/Left: {s}", .{why});
    if (clickStage(app, 3, 3, "sorted, click")) |why| return fail("sorted click expand/collapse: {s}", .{why});

    say("PASS: expanding and collapsing rows keeps the scroll, the rows on screen and the keyboard cursor", .{});
    teardown();
    return 0;
}

fn touch(comptime fmt: []const u8, args: anytype) void {
    var p_buf: [400]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&p_buf, fmt, args, 0) catch return;
    const f = c.fopen(p.ptr, "wb") orelse return;
    _ = c.fclose(f);
}

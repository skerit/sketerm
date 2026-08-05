//! Terminal-grid `atspi.Source`: the screen through `view.zig`.
//!
//! Every query rebuilds a `view.Snapshot` of the visible grid — the
//! grid IS the model, there is nothing cheaper to cache against, and
//! the bridge only calls in here once a screen reader is attached and
//! at most ~13 times a second.
//!
//! The diff region is the whole screen with a constant key, so a
//! terminal burst always diffs (which is what a redraw needs) and the
//! shared `emitNow` behaves exactly as the terminal-only bridge did.

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;
const atspi = @import("atspi.zig");
const view = @import("view.zig");

/// Create the pane's GL area as a SketermTermArea bound to `term`.
pub fn newArea(term: *Terminal) *c.GtkWidget {
    return atspi.newArea(
        .terminal,
        .{ .ctx = @ptrCast(term), .vtable = &vtable },
        "Terminal",
        term.allocator,
    );
}

const vtable: atspi.VTable = .{
    .contents = contents,
    .contentsAt = contentsAt,
    .caret = caret,
    .selections = selections,
    .region = region,
};

fn snap(ctx: *anyopaque) ?view.Snapshot {
    const term: *Terminal = @ptrCast(@alignCast(ctx));
    return view.build(term.screen, term.allocator) catch null;
}

fn contents(ctx: *anyopaque, alloc: std.mem.Allocator, c0: u32, c1: u32) ?[]u8 {
    var s = snap(ctx) orelse return null;
    defer s.deinit();
    return alloc.dupe(u8, s.byteRange(c0, c1)) catch null;
}

fn contentsAt(ctx: *anyopaque, alloc: std.mem.Allocator, off: u32, gran: atspi.Gran) ?atspi.Chunk {
    var s = snap(ctx) orelse return null;
    defer s.deinit();
    var rs: u32 = undefined;
    var re: u32 = undefined;
    switch (gran) {
        .character => {
            rs = @min(off, s.n_chars);
            re = @min(off + 1, s.n_chars);
        },
        .word => {
            const w = s.wordRange(off);
            rs = w.start;
            re = w.end;
        },
        .line => {
            const l = s.lineRange(off);
            rs = l.start;
            re = l.end;
        },
    }
    const text = alloc.dupe(u8, s.byteRange(rs, re)) catch return null;
    return .{ .text = text, .start = rs, .end = re };
}

fn caret(ctx: *anyopaque) u32 {
    var s = snap(ctx) orelse return 0;
    defer s.deinit();
    return s.caret;
}

/// A terminal has at most one selection, and a `.rectangular` one is
/// deliberately reported as none (see `view.Snapshot.sel_start`).
fn selections(ctx: *anyopaque, alloc: std.mem.Allocator) []atspi.Range {
    var s = snap(ctx) orelse return &.{};
    defer s.deinit();
    const a = s.sel_start orelse return &.{};
    const b = s.sel_end orelse return &.{};
    const out = alloc.alloc(atspi.Range, 1) catch return &.{};
    out[0] = .{ .start = a, .end = b };
    return out;
}

fn region(ctx: *anyopaque, alloc: std.mem.Allocator) ?atspi.Region {
    var s = snap(ctx) orelse return null;
    defer s.deinit();
    const text = alloc.dupe(u8, s.text) catch return null;
    return .{ .text = text, .char0 = 0, .key = 0 };
}

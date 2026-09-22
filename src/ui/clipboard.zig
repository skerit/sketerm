//! GDK clipboard bridge for the whole GUI, not only the terminal:
//! an async text read whose liveness stays with the caller
//! (`readFrom`), copies to CLIPBOARD and PRIMARY, and the terminal
//! paste path, which writes the text to the session with the
//! bracketed-paste markers when mode 2004 is on. What gets copied
//! comes from the caller; for a terminal that is the Screen's
//! selection model (`grid/selection.zig`).

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;
const cast = @import("../util/cast.zig");

const DrainHandle = @import("../terminal.zig").DrainHandle;

/// Which selection a read/copy targets.
pub const Which = enum { clipboard, primary };

pub fn clipboardFor(widget: *c.GtkWidget, which: Which) ?*c.GdkClipboard {
    const display = c.gtk_widget_get_display(widget);
    return switch (which) {
        .clipboard => c.gdk_display_get_clipboard(display),
        .primary => c.gdk_display_get_primary_clipboard(display),
    };
}

/// Heap wrapper for one outstanding async read. Freed exactly once,
/// in the finish callback, BEFORE the caller's cb runs (so the cb may
/// re-enter readFrom without tripping over it).
const ReadCtx = struct {
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
};

/// Async clipboard text read. On a true return `cb` runs exactly once
/// with the UTF-8 text, or null when the read failed or the
/// selection held no text, and receives the caller's own `ctx`
/// untouched, so the caller keeps whatever liveness fence it already
/// uses (a DrainHandle, a refcounted Fence, a pending-read counter)
/// and resolves it inside `cb`. This helper owns NO liveness of its
/// own. @return false when the request could not be issued at all,
/// meaning `cb` will never run and any per-call state the caller took
/// (a ref, a heap payload, a counter) is its to undo.
pub fn readFrom(
    allocator: std.mem.Allocator,
    clipboard_opt: ?*c.GdkClipboard,
    comptime cb: fn (ctx: ?*anyopaque, text: ?[]const u8) void,
    ctx: ?*anyopaque,
) bool {
    const clipboard = clipboard_opt orelse return false;
    const rc = allocator.create(ReadCtx) catch return false;
    rc.* = .{ .allocator = allocator, .ctx = ctx };
    c.gdk_clipboard_read_text_async(clipboard, null, @ptrCast(&Reader(cb).done), @ptrCast(rc));
    return true;
}

/// Async read of the widget's display clipboard (see `readFrom`).
pub fn readText(
    allocator: std.mem.Allocator,
    widget: *c.GtkWidget,
    comptime cb: fn (ctx: ?*anyopaque, text: ?[]const u8) void,
    ctx: ?*anyopaque,
) bool {
    return readFrom(allocator, clipboardFor(widget, .clipboard), cb, ctx);
}

fn Reader(comptime cb: fn (ctx: ?*anyopaque, text: ?[]const u8) void) type {
    return struct {
        fn done(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
            const rc: *ReadCtx = @ptrCast(@alignCast(user.?));
            const ctx = rc.ctx;
            rc.allocator.destroy(rc);
            const text_ptr = c.gdk_clipboard_read_text_finish(@ptrCast(@alignCast(source)), result, null);
            if (text_ptr == null) {
                cb(ctx, null);
                return;
            }
            defer c.g_free(text_ptr);
            const cstr: [*:0]const u8 = @ptrCast(text_ptr);
            cb(ctx, cstr[0..std.mem.len(cstr)]);
        }
    };
}

fn readClipboard(clipboard_opt: ?*c.GdkClipboard, terminal: *Terminal) void {
    _ = readFrom(terminal.allocator, clipboard_opt, onPasteRead, @ptrCast(terminal.drain));
}

pub fn pasteFromClipboard(widget: *c.GtkWidget, terminal: *Terminal) void {
    readClipboard(clipboardFor(widget, .clipboard), terminal);
}

pub fn pastePrimaryFromClipboard(widget: *c.GtkWidget, terminal: *Terminal) void {
    readClipboard(clipboardFor(widget, .primary), terminal);
}

/// The terminal paste path's liveness fence: the DrainHandle outlives
/// its Terminal, so a pane teardown between request and reply is
/// detected here instead of dereferenced.
fn onPasteRead(ctx: ?*anyopaque, text: ?[]const u8) void {
    const drain: *DrainHandle = @ptrCast(@alignCast(ctx.?));
    const pasted = text orelse return;
    if (!drain.alive.load(.acquire)) return;
    const term = drain.terminal orelse return;
    pasteText(term, pasted);
}

/// Send pasted text to the PTY, honouring bracketed paste.
pub fn pasteText(term: *Terminal, pasted: []const u8) void {
    emitPaste(pasted, term.screen.bracketed_paste, term, Terminal.writeUserInput);
}

/// Hand `sink` the bytes a paste of `pasted` sends, in order; when
/// bracketed, every ESC is dropped so a pasted "\x1b[201~" cannot end
/// the wrapping early (xterm convention).
pub fn emitPaste(pasted: []const u8, bracketed: bool, ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const u8) void) void {
    if (pasted.len == 0) return;
    if (bracketed) {
        sink(ctx, "\x1b[200~");
        var start: usize = 0;
        for (pasted, 0..) |b, i| {
            if (b == 0x1B) {
                if (i > start) sink(ctx, pasted[start..i]);
                start = i + 1;
            }
        }
        if (start < pasted.len) sink(ctx, pasted[start..]);
        sink(ctx, "\x1b[201~");
    } else {
        sink(ctx, pasted);
    }
}

/// Copy a plain (not necessarily 0-terminated) slice to the widget's
/// display clipboard. GDK wants a C string, so short text rides a
/// stack buffer and anything longer is duped through the CALLER's
/// allocator — the same one the read path (`readFrom`) already takes,
/// so one logical clipboard operation never straddles two heaps. An
/// OOM on the dupe drops the copy silently, matching every open-coded
/// site this replaced.
pub fn copyText(allocator: std.mem.Allocator, widget: *c.GtkWidget, text: []const u8) void {
    copyTextTo(allocator, clipboardFor(widget, .clipboard), text);
}

pub fn copyTextTo(allocator: std.mem.Allocator, clipboard_opt: ?*c.GdkClipboard, text: []const u8) void {
    const clipboard = clipboard_opt orelse return;
    var stack: [512:0]u8 = undefined;
    if (text.len < stack.len) {
        @memcpy(stack[0..text.len], text);
        stack[text.len] = 0;
        c.gdk_clipboard_set_text(clipboard, &stack);
        return;
    }
    const z = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(z);
    c.gdk_clipboard_set_text(clipboard, z.ptr);
}

pub fn copyToClipboard(widget: *c.GtkWidget, text: [:0]const u8) void {
    const display = c.gtk_widget_get_display(widget);
    const clipboard = c.gdk_display_get_clipboard(display);
    c.gdk_clipboard_set_text(clipboard, text.ptr);
}

/// Sets the PRIMARY (X11/select) clipboard. Called when the user
/// finishes a drag-selection so middle-click paste matches the
/// xterm convention.
pub fn copyToPrimary(widget: *c.GtkWidget, text: [:0]const u8) void {
    const display = c.gtk_widget_get_display(widget);
    const clipboard = c.gdk_display_get_primary_clipboard(display);
    c.gdk_clipboard_set_text(clipboard, text.ptr);
}

// -- tests --------------------------------------------------------------

/// Records what `emitPaste` would have written to the PTY.
const PasteLog = struct {
    bytes: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    empty_writes: usize = 0,
    oom: bool = false,

    fn sink(self: *PasteLog, chunk: []const u8) void {
        self.writes += 1;
        if (chunk.len == 0) self.empty_writes += 1;
        self.bytes.appendSlice(std.testing.allocator, chunk) catch {
            self.oom = true;
        };
    }

    fn deinit(self: *PasteLog) void {
        self.bytes.deinit(std.testing.allocator);
    }

    fn run(self: *PasteLog, text: []const u8, bracketed: bool) !void {
        emitPaste(text, bracketed, self, sink);
        try std.testing.expect(!self.oom);
        try std.testing.expectEqual(@as(usize, 0), self.empty_writes);
    }
};

test "an unbracketed paste reaches the PTY byte for byte, ESC included" {
    var log: PasteLog = .{};
    defer log.deinit();
    try log.run("ls\x1b[A\n", false);
    try std.testing.expectEqualStrings("ls\x1b[A\n", log.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), log.writes);
}

test "a bracketed paste is wrapped in the 2004 markers and loses every ESC" {
    var log: PasteLog = .{};
    defer log.deinit();
    try log.run("a\x1bb\nc", true);
    try std.testing.expectEqualStrings("\x1b[200~ab\nc\x1b[201~", log.bytes.items);
}

test "a pasted end marker cannot close the bracket early" {
    var log: PasteLog = .{};
    defer log.deinit();
    try log.run("x\x1b[201~rm -rf ~\n", true);
    try std.testing.expectEqualStrings("\x1b[200~x[201~rm -rf ~\n\x1b[201~", log.bytes.items);
    // The only end marker the shell sees is ours, at the very end.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log.bytes.items, "\x1b[201~"));
    try std.testing.expect(std.mem.endsWith(u8, log.bytes.items, "\x1b[201~"));
}

test "ESC at the edges and in runs never produces an empty write" {
    var log: PasteLog = .{};
    defer log.deinit();
    try log.run("\x1b\x1bab\x1b", true);
    try std.testing.expectEqualStrings("\x1b[200~ab\x1b[201~", log.bytes.items);

    var only_esc: PasteLog = .{};
    defer only_esc.deinit();
    try only_esc.run("\x1b\x1b\x1b", true);
    try std.testing.expectEqualStrings("\x1b[200~\x1b[201~", only_esc.bytes.items);
}

test "an empty paste sends nothing, not even the markers" {
    var log: PasteLog = .{};
    defer log.deinit();
    try log.run("", true);
    try log.run("", false);
    try std.testing.expectEqual(@as(usize, 0), log.writes);
}

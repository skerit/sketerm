//! Clipboard bridge: paste from GdkClipboard → PTY (with bracketed
//! paste markers when mode 2004 enabled).
//!
//! Copy uses GdkClipboard.set_text. Selection model arrives later.

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
/// When bracketed: scrub embedded ESC bytes so a pasted "\x1b[201~"
/// can't break out of the wrapping early (xterm convention).
pub fn pasteText(term: *Terminal, pasted: []const u8) void {
    if (pasted.len == 0) return;
    if (term.screen.bracketed_paste) {
        term.writeUserInput("\x1b[200~");
        var start: usize = 0;
        for (pasted, 0..) |b, i| {
            if (b == 0x1B) {
                if (i > start) term.writeUserInput(pasted[start..i]);
                start = i + 1;
            }
        }
        if (start < pasted.len) term.writeUserInput(pasted[start..]);
        term.writeUserInput("\x1b[201~");
    } else {
        term.writeUserInput(pasted);
    }
}

/// Copy a plain (not necessarily 0-terminated) slice to the widget's
/// display clipboard. GDK wants a C string, so short text rides a
/// stack buffer and anything longer is duped; an OOM on the dupe
/// drops the copy silently, matching every open-coded site this
/// replaced.
pub fn copyText(widget: *c.GtkWidget, text: []const u8) void {
    copyTextTo(clipboardFor(widget, .clipboard), text);
}

pub fn copyTextTo(clipboard_opt: ?*c.GdkClipboard, text: []const u8) void {
    const clipboard = clipboard_opt orelse return;
    var stack: [512:0]u8 = undefined;
    if (text.len < stack.len) {
        @memcpy(stack[0..text.len], text);
        stack[text.len] = 0;
        c.gdk_clipboard_set_text(clipboard, &stack);
        return;
    }
    const z = std.heap.c_allocator.dupeZ(u8, text) catch return;
    defer std.heap.c_allocator.free(z);
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

//! Clipboard bridge: paste from GdkClipboard → PTY (with bracketed
//! paste markers when mode 2004 enabled).
//!
//! Copy uses GdkClipboard.set_text. Selection model arrives later.

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;

pub fn pasteFromClipboard(widget: *c.GtkWidget, terminal: *Terminal) void {
    const display = c.gtk_widget_get_display(widget);
    const clipboard = c.gdk_display_get_clipboard(display);
    c.gdk_clipboard_read_text_async(
        clipboard,
        null,
        @ptrCast(&onPasteRead),
        @ptrCast(terminal),
    );
}

pub fn pastePrimaryFromClipboard(widget: *c.GtkWidget, terminal: *Terminal) void {
    const display = c.gtk_widget_get_display(widget);
    const clipboard = c.gdk_display_get_primary_clipboard(display);
    c.gdk_clipboard_read_text_async(
        clipboard,
        null,
        @ptrCast(&onPasteRead),
        @ptrCast(terminal),
    );
}

fn onPasteRead(source: ?*c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const clipboard: *c.GdkClipboard = @ptrCast(source);
    const term: *Terminal = @ptrCast(@alignCast(user.?));
    const text_ptr = c.gdk_clipboard_read_text_finish(clipboard, result, null);
    if (text_ptr == null) return;
    defer c.g_free(text_ptr);

    const cstr: [*:0]const u8 = @ptrCast(text_ptr);
    const len = std.mem.len(cstr);
    if (len == 0) return;

    // Wrap with bracketed-paste markers only when mode 2004 enabled.
    if (term.screen.bracketed_paste) _ = term.pty.writeAll("\x1b[200~");
    _ = term.pty.writeAll(cstr[0..len]);
    if (term.screen.bracketed_paste) _ = term.pty.writeAll("\x1b[201~");
}

pub fn copyToClipboard(widget: *c.GtkWidget, text: [:0]const u8) void {
    const display = c.gtk_widget_get_display(widget);
    const clipboard = c.gdk_display_get_clipboard(display);
    c.gdk_clipboard_set_text(clipboard, text.ptr);
}

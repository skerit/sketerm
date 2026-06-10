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
    pasteText(term, cstr[0..std.mem.len(cstr)]);
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

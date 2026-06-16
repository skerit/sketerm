//! macOS/AppKit accessibility bridge.
//!
//! The Cocoa twin of `atspi.zig`: it exposes a terminal pane to
//! NSAccessibility (VoiceOver, braille, the Accessibility Inspector)
//! as a text element. macOS has no "terminal" role, so the pane
//! reports `NSAccessibilityTextAreaRole` — the same choice Terminal.app
//! and iTerm2 make.
//!
//! All the text model lives in the platform-neutral `view.zig`, exactly
//! as the Linux bridge uses it: every query rebuilds a `view.Snapshot`,
//! answers, and frees it. The NSAccessibility protocol itself is ObjC,
//! so — matching the `winstream/sck_shim.m` convention — the actual
//! `NSView` subclass lives in `nsax_shim.m` behind a plain C ABI, and
//! calls back into the `export fn`s below for every answer. This file
//! owns the one genuinely tricky part: NSRange is in **UTF-16 code
//! units** while the neutral snapshot speaks **codepoints**, so the
//! callbacks translate at the boundary using `Snapshot.char_to_utf16`
//! (forward via `utf16At`, inverse via `charForUtf16`). The shim only
//! ever sees UTF-16 offsets and UTF-8 bytes.
//!
//! Wiring (when the native AppKit frontend lands): create the pane's
//! view with `newView(term)`, drop the bridge's owning reference with
//! `releaseView` once it is in the view hierarchy, and call
//! `notifyChanged(view)` from the pane's render-on-change path — the
//! macOS analog of `pane.zig`'s `a11y.notifyChanged` (atspi) call.

const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("../terminal.zig").Terminal;
const view = @import("view.zig");

// ── C ABI exposed by nsax_shim.m (the SketermTermView NSView) ────────
// Declared unconditionally so this file type-checks on every platform;
// only referenced (and thus link-required) on macOS, where the shim is
// linked in. The opaque pointer is a retained `NSView *`.
extern fn sketerm_nsax_new_view(term: ?*anyopaque) ?*anyopaque;
extern fn sketerm_nsax_set_terminal(nsview: ?*anyopaque, term: ?*anyopaque) void;
extern fn sketerm_nsax_notify_changed(obj: ?*anyopaque) void;
extern fn sketerm_nsax_release_view(nsview: ?*anyopaque) void;
extern fn sketerm_nsax_content_view(nswindow: ?*anyopaque) ?*anyopaque;
extern fn sketerm_nsax_attach(content_view: ?*anyopaque, term: ?*anyopaque) ?*anyopaque;
extern fn sketerm_nsax_detach(content_view: ?*anyopaque, element: ?*anyopaque) void;
extern fn sketerm_nsax_set_frame_in_parent(element: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) void;
extern fn sketerm_nsax_selfcheck(content_view: ?*anyopaque, element: ?*anyopaque) c_int;

/// GDK macOS: the NSWindow backing a GdkMacosSurface (public GDK API,
/// returns a `gpointer`/`NSWindow *`). Declared here so we don't have
/// to pull `gdk/macos/gdkmacos.h` through translate-c.
extern fn gdk_macos_surface_get_native_window(surface: ?*anyopaque) ?*anyopaque;

/// Create the pane's accessible `NSView` bound to `term` (the AppKit
/// analog of `atspi.newArea`). Returns an opaque, +1-retained
/// `NSView *`; insert it into the view hierarchy, then call
/// `releaseView` to balance the bridge's reference.
pub fn newView(term: *Terminal) ?*anyopaque {
    return sketerm_nsax_new_view(@ptrCast(term));
}

/// Re-point an existing accessible view at a (possibly new) terminal.
/// `terminal.screen` is swapped wholesale on a remote/mux snapshot, but
/// the `*Terminal` handle is stable — so this is only needed if a view
/// is reused across terminals, not on a snapshot swap.
pub fn setTerminal(nsview: *anyopaque, term: *Terminal) void {
    sketerm_nsax_set_terminal(nsview, @ptrCast(term));
}

/// Tell VoiceOver the value/caret changed. Posts
/// NSAccessibilityValueChanged + SelectedTextChanged. Cheap; AX clients
/// re-query on demand. Call from the pane's render-on-change path.
/// Works on a SketermTermView or a SketermTermAXElement.
pub fn notifyChanged(obj: *anyopaque) void {
    sketerm_nsax_notify_changed(obj);
}

/// Release the bridge's owning reference on a view from `newView`.
pub fn releaseView(nsview: *anyopaque) void {
    sketerm_nsax_release_view(nsview);
}

// ── GTK-on-macOS attachment (current frontend) ───────────────────────
// GTK4 has no NSAccessibility backend, so the pane's text cannot reach
// VoiceOver through GtkAccessibleText (atspi.zig) on macOS. Instead we
// attach a SketermTermAXElement per pane to the window's GdkMacos
// content NSView, which IS visible to VoiceOver.

/// The NSWindow content NSView for a GdkMacosSurface, or null. Pass the
/// pane's `GdkSurface` (from `gtk_native_get_surface`).
pub fn contentView(surface: *anyopaque) ?*anyopaque {
    const nswindow = gdk_macos_surface_get_native_window(surface) orelse return null;
    return sketerm_nsax_content_view(nswindow);
}

/// Attach a pane element bound to `term` to a content view. Returns a
/// retained element handle; pass it back to `detach`.
pub fn attach(content_view: *anyopaque, term: *Terminal) ?*anyopaque {
    return sketerm_nsax_attach(content_view, @ptrCast(term));
}

/// Remove + release an element previously returned by `attach`.
pub fn detach(content_view: *anyopaque, element: *anyopaque) void {
    sketerm_nsax_detach(content_view, element);
}

/// Position an attached element within its content view (GTK top-left
/// widget coords; the shim flips to AppKit space if needed).
pub fn setFrameInParent(element: *anyopaque, x: f64, y: f64, w: f64, h: f64) void {
    sketerm_nsax_set_frame_in_parent(element, x, y, w, h);
}

/// In-process wiring check (no TCC grant needed): bit0 element is a
/// child of the content view, bit1 role is AXTextArea, bit2 value
/// non-empty. 7 = fully discoverable by a VoiceOver client.
pub fn selfCheck(content_view: *anyopaque, element: *anyopaque) c_int {
    return sketerm_nsax_selfcheck(content_view, element);
}

comptime {
    // Force the shim-calling wrappers to be type-checked + emitted on
    // macOS (where nsax_shim.m is linked), so the Zig→ObjC ABI is
    // validated even before any caller references them. On Linux they
    // stay lazy/unreferenced — no link dependency on the shim.
    if (builtin.os.tag == .macos) {
        _ = &newView;
        _ = &setTerminal;
        _ = &notifyChanged;
        _ = &releaseView;
        _ = &contentView;
        _ = &attach;
        _ = &detach;
        _ = &setFrameInParent;
        _ = &selfCheck;
    }
}

// ── helpers (codepoint ↔ UTF-16, line lookup) ────────────────────────

fn termOf(p: ?*anyopaque) ?*Terminal {
    return @ptrCast(@alignCast(p orelse return null));
}

/// Inverse of `Snapshot.utf16At`: the character (codepoint) offset whose
/// UTF-16 start is the largest `<= u16off`. `char_to_utf16` is monotonic
/// non-decreasing with len `n_chars + 1`, so a binary search lands the
/// char that an NSRange offset falls inside (a mid-surrogate offset,
/// which AX should never send, resolves to its containing char). Clamps
/// to the end-of-text sentinel.
fn charForUtf16(s: *const view.Snapshot, u16off: usize) u32 {
    const total = s.utf16At(s.n_chars);
    const target: u32 = @intCast(@min(u16off, @as(usize, total)));
    var lo: u32 = 0;
    var hi: u32 = s.n_chars; // inclusive: index n_chars is the sentinel
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (s.char_to_utf16[mid] <= target) lo = mid else hi = mid - 1;
    }
    return lo;
}

/// 0-based visible row index containing character offset `ch`.
fn lineForChar(s: *const view.Snapshot, ch: u32) i64 {
    var i: usize = s.line_starts.len;
    while (i > 0) {
        i -= 1;
        if (s.line_starts[i] <= ch) return @intCast(i);
    }
    return 0;
}

/// Build a snapshot for `term`'s live screen (deref `term.screen` now —
/// it is swapped wholesale on a remote snapshot).
fn snap(term: *Terminal) ?view.Snapshot {
    return view.build(term.screen, term.allocator) catch null;
}

/// malloc a copy of `bytes` for the ObjC side to take ownership of and
/// `free`. Empty → null (the shim maps null to @""). Pairs malloc/free
/// across the boundary, so it must NOT use the Zig GPA.
fn dupC(bytes: []const u8, out_len: *usize) ?[*]u8 {
    if (bytes.len == 0) {
        out_len.* = 0;
        return null;
    }
    const raw = std.c.malloc(bytes.len) orelse {
        out_len.* = 0;
        return null;
    };
    const dst: [*]u8 = @ptrCast(raw);
    @memcpy(dst[0..bytes.len], bytes);
    out_len.* = bytes.len;
    return dst;
}

// ── NSAccessibility callbacks (called from nsax_shim.m) ──────────────
// Offsets/ranges in/out are UTF-16 code units; strings are malloc'd
// UTF-8 the caller frees. Each rebuilds + frees a Snapshot, mirroring
// the per-query pattern in atspi.zig.

/// accessibilityValue / the full text as UTF-8.
export fn sketerm_nsax_value(term_p: ?*anyopaque, out_len: *usize) callconv(.c) ?[*]u8 {
    out_len.* = 0;
    const term = termOf(term_p) orelse return null;
    var s = snap(term) orelse return null;
    defer s.deinit();
    return dupC(s.text, out_len);
}

/// accessibilityNumberOfCharacters / value length, in UTF-16 units
/// (== NSString.length of the value).
export fn sketerm_nsax_length(term_p: ?*anyopaque) callconv(.c) usize {
    const term = termOf(term_p) orelse return 0;
    var s = snap(term) orelse return 0;
    defer s.deinit();
    return s.utf16At(s.n_chars);
}

/// accessibilityStringForRange: UTF-8 substring for UTF-16 [loc, loc+len).
export fn sketerm_nsax_string_for_range(
    term_p: ?*anyopaque,
    loc: usize,
    len: usize,
    out_len: *usize,
) callconv(.c) ?[*]u8 {
    out_len.* = 0;
    const term = termOf(term_p) orelse return null;
    var s = snap(term) orelse return null;
    defer s.deinit();
    const c0 = charForUtf16(&s, loc);
    const c1 = charForUtf16(&s, loc +| len);
    return dupC(s.byteRange(c0, c1), out_len);
}

/// accessibilitySelectedTextRange: the caret as a zero-length insertion
/// point. Returns the UTF-16 location; the shim makes NSMakeRange(loc, 0).
export fn sketerm_nsax_caret(term_p: ?*anyopaque) callconv(.c) usize {
    const term = termOf(term_p) orelse return 0;
    var s = snap(term) orelse return 0;
    defer s.deinit();
    return s.utf16At(s.caret);
}

/// accessibilityLineForIndex / InsertionPointLineNumber: 0-based row for
/// a UTF-16 index. -1 if the snapshot can't be built.
export fn sketerm_nsax_line_for_index(term_p: ?*anyopaque, index: usize) callconv(.c) c_longlong {
    const term = termOf(term_p) orelse return -1;
    var s = snap(term) orelse return -1;
    defer s.deinit();
    return lineForChar(&s, charForUtf16(&s, index));
}

/// accessibilityRangeForLine: UTF-16 range (incl. trailing newline) of a
/// 0-based row. Returns 1 + fills loc/len on success, 0 if out of range.
export fn sketerm_nsax_range_for_line(
    term_p: ?*anyopaque,
    line: c_longlong,
    out_loc: *usize,
    out_len: *usize,
) callconv(.c) c_int {
    out_loc.* = 0;
    out_len.* = 0;
    const term = termOf(term_p) orelse return 0;
    var s = snap(term) orelse return 0;
    defer s.deinit();
    if (line < 0 or @as(usize, @intCast(line)) >= s.line_starts.len) return 0;
    const li: usize = @intCast(line);
    const start = s.line_starts[li];
    const end = if (li + 1 < s.line_starts.len) s.line_starts[li + 1] else s.n_chars;
    const start16 = s.utf16At(start);
    const end16 = s.utf16At(end);
    out_loc.* = start16;
    out_len.* = end16 - start16;
    return 1;
}

// ── tests ────────────────────────────────────────────────────────────
// Exercise the codepoint↔UTF-16 boundary math (the macOS-specific risk)
// against the neutral snapshot. The ObjC shim is verified by `zig build
// test` linking it on macOS; these run everywhere.

const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

fn feed(screen: *Screen, s: []const u8) void {
    for (s) |ch| switch (ch) {
        '\r', '\n' => screen.apply(.{ .execute = ch }),
        else => screen.apply(.{ .print = ch }),
    };
}

test "charForUtf16 is the inverse of utf16At across an astral char" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 6, 1);
    defer screen.deinit();

    // "a😀b": UTF-16 layout is a=0, emoji=1..2 (surrogate pair), b=3.
    screen.apply(.{ .print = 'a' });
    screen.apply(.{ .print = 0x1F600 });
    screen.apply(.{ .print = 'b' });

    var s = try view.build(screen, testing.allocator);
    defer s.deinit();

    // Every char's UTF-16 start round-trips back to that char.
    var ci: u32 = 0;
    while (ci <= s.n_chars) : (ci += 1) {
        try testing.expectEqual(ci, charForUtf16(&s, s.utf16At(ci)));
    }
    // An offset landing on the trailing surrogate of the emoji (2)
    // resolves to the emoji char (index 1), not 'b'.
    try testing.expectEqual(@as(u32, 1), charForUtf16(&s, 2));
    // Past-the-end clamps to the end-of-text sentinel.
    try testing.expectEqual(s.n_chars, charForUtf16(&s, 9999));
}

test "string_for_range slices by UTF-16 offsets, not codepoints" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 6, 1);
    defer screen.deinit();

    screen.apply(.{ .print = 'a' });
    screen.apply(.{ .print = 0x1F600 });
    screen.apply(.{ .print = 'b' });

    var s = try view.build(screen, testing.allocator);
    defer s.deinit();

    // UTF-16 [1,3) is exactly the emoji's surrogate pair → its UTF-8.
    const c0 = charForUtf16(&s, 1);
    const c1 = charForUtf16(&s, 3);
    try testing.expectEqualStrings("\u{1F600}", s.byteRange(c0, c1));
    // UTF-16 [3,4) is 'b' (would be the wrong char under codepoint math).
    try testing.expectEqualStrings("b", s.byteRange(charForUtf16(&s, 3), charForUtf16(&s, 4)));
}

test "line/range mapping over a multi-row screen in UTF-16" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 10, 3);
    defer screen.deinit();

    // `feed` walks bytes, so it can't carry a multibyte codepoint —
    // apply the emoji as one print, like view.zig's astral test.
    feed(screen, "hi\r\n");
    screen.apply(.{ .print = 'x' });
    screen.apply(.{ .print = 0x1F600 }); // row 1 has an astral char
    feed(screen, "\r\n");
    screen.apply(.{ .print = 'z' });

    var s = try view.build(screen, testing.allocator);
    defer s.deinit();

    // Char layout: row0 "hi"(0,1) \n(2); row1 "x"(3) emoji(4) \n(5);
    // row2 "z"(6). UTF-16 layout shifts everything after the emoji +1.
    try testing.expectEqual(@as(u32, 3), s.line_starts[1]);
    try testing.expectEqual(@as(u32, 6), s.line_starts[2]);

    // line_for: a UTF-16 index inside row 1 (the 'x', at UTF-16 3) → row 1.
    try testing.expectEqual(@as(i64, 1), lineForChar(&s, charForUtf16(&s, s.utf16At(3))));
    // The 'z' on row 2 sits at UTF-16 7 (one past the emoji's extra unit).
    try testing.expectEqual(@as(u32, 7), s.utf16At(6));
    try testing.expectEqual(@as(i64, 2), lineForChar(&s, charForUtf16(&s, 7)));

    // range_for_line(1) covers "x😀\n": chars [3,6) → UTF-16 [3,7), len 4.
    const start = s.line_starts[1];
    const end = s.line_starts[2];
    try testing.expectEqual(@as(u32, 3), s.utf16At(start));
    try testing.expectEqual(@as(u32, 4), s.utf16At(end) - s.utf16At(start));
}

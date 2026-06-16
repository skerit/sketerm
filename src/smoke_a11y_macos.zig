//! Headless macOS NSAccessibility smoke (`zig build smoke-a11y`).
//!
//! Drives a REAL `SketermTermView` (a11y/nsax_shim.m) through the
//! NSAccessibility selectors VoiceOver / the Accessibility Inspector
//! call — value, character count, caret range, substring-for-range,
//! line lookups — and asserts they match a known screen. The content
//! includes an astral char (😀) so the whole codepoint→UTF-16 path is
//! exercised end-to-end (ObjC dispatch → a11y/nsax.zig → view.zig),
//! the one place where the AT-SPI and NSAccessibility offset domains
//! diverge.
//!
//! This is the macOS analog of the Linux side's "plain AT-SPI client
//! reading char_count / caret_offset / contents / caret line" check.
//! It does not need a window, NSApplication, or the (not-yet-built)
//! AppKit pane frontend: the accessibility methods are plain calls.

const std = @import("std");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;
const Terminal = @import("terminal.zig").Terminal;

comptime {
    // Pull in the bridge's `export fn` callbacks so the linked shim
    // (sketerm_nsax_value, …) resolves against them in this binary.
    _ = @import("a11y/nsax.zig");
}

// nsax_shim.m: factory + release.
extern fn sketerm_nsax_new_view(term: ?*anyopaque) ?*anyopaque;
extern fn sketerm_nsax_release_view(view: ?*anyopaque) void;

// nsax_probe.m: send the real AX selectors to the view.
extern fn sketerm_axprobe_is_element(view: ?*anyopaque) c_int;
extern fn sketerm_axprobe_role_is_textarea(view: ?*anyopaque) c_int;
extern fn sketerm_axprobe_value(view: ?*anyopaque, out_len: *usize) ?[*]u8;
extern fn sketerm_axprobe_num_chars(view: ?*anyopaque) c_long;
extern fn sketerm_axprobe_caret(view: ?*anyopaque, out_loc: *usize, out_len: *usize) void;
extern fn sketerm_axprobe_string_for_range(view: ?*anyopaque, loc: usize, len: usize, out_len: *usize) ?[*]u8;
extern fn sketerm_axprobe_line_for_index(view: ?*anyopaque, idx: usize) c_long;
extern fn sketerm_axprobe_insertion_line(view: ?*anyopaque) c_long;
extern fn sketerm_axprobe_range_for_line(view: ?*anyopaque, line: c_long, out_loc: *usize, out_len: *usize) c_int;
extern fn sketerm_axprobe_visible_len(view: ?*anyopaque) c_long;

var failures: u32 = 0;

fn check(ok: bool, comptime label: []const u8) void {
    if (ok) {
        std.debug.print("  ok   {s}\n", .{label});
    } else {
        std.debug.print("  FAIL {s}\n", .{label});
        failures += 1;
    }
}

/// Take ownership of a malloc'd UTF-8 buffer from a probe call as a
/// slice; caller frees with `freeC`.
fn takeC(p: ?[*]u8, len: usize) []const u8 {
    if (p == null or len == 0) return "";
    return p.?[0..len];
}
fn freeC(p: ?[*]u8) void {
    if (p) |ptr| std.c.free(ptr);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try Pool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 6, 2);
    defer screen.deinit();

    // Row 0: "a😀b" (astral char in the middle). Row 1: "X", cursor
    // parked after it. CR/LF advance rows.
    screen.apply(.{ .print = 'a' });
    screen.apply(.{ .print = 0x1F600 });
    screen.apply(.{ .print = 'b' });
    screen.apply(.{ .execute = '\r' });
    screen.apply(.{ .execute = '\n' });
    screen.apply(.{ .print = 'X' });

    // The bridge reads only `screen` + `allocator` off the Terminal;
    // the rest stays undefined and untouched.
    var term: Terminal = undefined;
    term.screen = screen;
    term.allocator = allocator;

    const view = sketerm_nsax_new_view(&term) orelse {
        std.debug.print("FAIL: sketerm_nsax_new_view returned null\n", .{});
        std.process.exit(1);
    };
    defer sketerm_nsax_release_view(view);

    std.debug.print("macOS NSAccessibility smoke (SketermTermView):\n", .{});

    // Identity + role.
    check(sketerm_axprobe_is_element(view) == 1, "isAccessibilityElement == YES");
    check(sketerm_axprobe_role_is_textarea(view) == 1, "accessibilityRole == AXTextArea");

    // Value: the full visible text, rows joined by '\n'.
    var vlen: usize = 0;
    const vp = sketerm_axprobe_value(view, &vlen);
    defer freeC(vp);
    check(std.mem.eql(u8, takeC(vp, vlen), "a\u{1F600}b\nX"), "accessibilityValue == \"a😀b\\nX\"");

    // numberOfCharacters is the value's UTF-16 length: a(1) 😀(2) b(1)
    // \n(1) X(1) = 6 — NOT the 5 codepoints.
    check(sketerm_axprobe_num_chars(view) == 6, "accessibilityNumberOfCharacters == 6 (UTF-16)");
    check(sketerm_axprobe_visible_len(view) == 6, "accessibilityVisibleCharacterRange.length == 6");

    // Caret: zero-length insertion point after 'X' (UTF-16 offset 6).
    var cloc: usize = 0;
    var clen: usize = 99;
    sketerm_axprobe_caret(view, &cloc, &clen);
    check(cloc == 6 and clen == 0, "accessibilitySelectedTextRange == {6, 0}");
    check(sketerm_axprobe_insertion_line(view) == 1, "accessibilityInsertionPointLineNumber == 1");

    // Substring by UTF-16 range — the whole point of char_to_utf16.
    {
        var l: usize = 0;
        const p = sketerm_axprobe_string_for_range(view, 1, 2, &l); // emoji's surrogate pair
        defer freeC(p);
        check(std.mem.eql(u8, takeC(p, l), "\u{1F600}"), "stringForRange{1,2} == \"😀\"");
    }
    {
        var l: usize = 0;
        const p = sketerm_axprobe_string_for_range(view, 5, 1, &l); // 'X', shifted by the emoji's extra unit
        defer freeC(p);
        check(std.mem.eql(u8, takeC(p, l), "X"), "stringForRange{5,1} == \"X\" (UTF-16, not codepoint)");
    }

    // Line lookups in UTF-16 units.
    check(sketerm_axprobe_line_for_index(view, 0) == 0, "lineForIndex(0) == 0");
    check(sketerm_axprobe_line_for_index(view, 6) == 1, "lineForIndex(6) == 1");

    {
        var l: usize = 0;
        var n: usize = 0;
        _ = sketerm_axprobe_range_for_line(view, 0, &l, &n);
        check(l == 0 and n == 5, "rangeForLine(0) == {0, 5} (\"a😀b\\n\")");
    }
    {
        var l: usize = 0;
        var n: usize = 0;
        _ = sketerm_axprobe_range_for_line(view, 1, &l, &n);
        check(l == 5 and n == 1, "rangeForLine(1) == {5, 1} (\"X\")");
    }

    if (failures == 0) {
        std.debug.print("PASS: NSAccessibility round-trip matches the screen.\n", .{});
    } else {
        std.debug.print("FAILED: {d} assertion(s).\n", .{failures});
        std.process.exit(1);
    }
}

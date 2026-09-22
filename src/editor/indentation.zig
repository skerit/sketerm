//! Effective indentation for one document: what Tab inserts, how wide
//! an indent level is, and how wide a tab character renders.
//!
//! Each property is taken from the highest source that says anything
//! about it, in this order (docs/editor-commands.md, "Indentation"):
//!
//!   1. the per-tab override (palette commands),
//!   2. a language that REQUIRES tabs (Makefile recipes),
//!   3. `.editorconfig`,
//!   4. the document's own content (`detect`),
//!   5. a language that PREFERS tabs (gofmt),
//!   6. the global `editor_insert_spaces` / `editor_tab_width`.
//!
//! GTK-free and allocation-free.

const std = @import("std");
const Rope = @import("rope.zig").Rope;
const languages = @import("languages.zig");
const editorconfig = @import("editorconfig.zig");

pub const Style = enum { tabs, spaces };

/// Where the effective style came from, for the status line.
pub const Source = enum {
    override,
    language,
    editorconfig,
    detected,
    config,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .override => "set for this tab",
            .language => "language",
            .editorconfig => ".editorconfig",
            .detected => "detected",
            .config => "default",
        };
    }
};

pub const Settings = struct {
    style: Style,
    /// Columns one indent level spans.
    size: u16,
    /// Columns a tab character advances to.
    tab_width: u16,
    source: Source,

    pub fn useSpaces(self: Settings) bool {
        return self.style == .spaces;
    }

    /// "Spaces: 4" / "Tabs: 8", the status-line fragment.
    pub fn describe(self: Settings, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}: {d} ({s})", .{
            if (self.style == .spaces) "Spaces" else "Tabs",
            if (self.style == .spaces) self.size else self.tab_width,
            self.source.label(),
        }) catch "";
    }
};

/// What the content says, when it says anything.
pub const Detected = struct {
    style: Style,
    /// Null when the content shows spaces but no consistent step.
    size: ?u16 = null,
};

/// A per-tab override; null fields defer to the lower sources.
pub const Override = struct {
    style: ?Style = null,
    width: ?u16 = null,

    pub fn isEmpty(self: Override) bool {
        return self.style == null and self.width == null;
    }
};

pub const Inputs = struct {
    override: Override = .{},
    tabs: languages.TabPolicy = .none,
    ec: editorconfig.Props = .{},
    detected: ?Detected = null,
    config_spaces: bool = true,
    config_width: u16 = 4,
};

pub fn resolve(in: Inputs) Settings {
    var style: Style = if (in.config_spaces) .spaces else .tabs;
    var source: Source = .config;
    if (in.override.style) |s| {
        style = s;
        source = .override;
    } else if (in.tabs == .require) {
        style = .tabs;
        source = .language;
    } else if (in.ec.indent_style) |s| {
        style = if (s == .tab) .tabs else .spaces;
        source = .editorconfig;
    } else if (in.detected) |d| {
        style = d.style;
        source = .detected;
    } else if (in.tabs == .prefer) {
        style = .tabs;
        source = .language;
    }

    const config_w = clampWidth(in.config_width);
    const detected_size: ?u16 = if (in.detected) |d| (if (d.style == .spaces) d.size else null) else null;
    const size: u16 = in.override.width orelse in.ec.indentCols() orelse detected_size orelse in.ec.tab_width orelse config_w;
    const tab_width: u16 = (if (style == .tabs) in.override.width else null) orelse in.ec.tab_width orelse in.ec.indentCols() orelse config_w;
    return .{ .style = style, .size = clampWidth(size), .tab_width = clampWidth(tab_width), .source = source };
}

fn clampWidth(w: u16) u16 {
    return std.math.clamp(w, 1, 16);
}

// ======================================================================
// Detection
// ======================================================================

/// How much of a document detection reads.
pub const DETECT_BYTES: usize = 256 * 1024;
pub const DETECT_LINES: usize = 4000;

/// Guess the indentation a document already uses: tabs vs spaces by
/// counting indented lines, and the space step from the changes in
/// indentation between consecutive lines (the step 1 is ignored: it is
/// almost always a C block comment's ` * ` continuation). Null when the
/// content has no indented lines at all.
pub fn detect(rope: *const Rope) ?Detected {
    var tab_lines: usize = 0;
    var space_lines: usize = 0;
    var steps = [_]usize{0} ** 17;
    var prev_spaces: usize = 0;

    var it = rope.iterateRange(0, @min(rope.len(), DETECT_BYTES));
    var at_line_start = true;
    var leading: usize = 0;
    var first: u8 = 0;
    var lines: usize = 0;
    var mixed = false;
    outer: while (it.next()) |chunk| {
        for (chunk) |b| {
            if (at_line_start) {
                switch (b) {
                    ' ', '\t' => {
                        if (leading == 0) first = b else if (b != first) mixed = true;
                        leading += 1;
                        continue;
                    },
                    '\r' => continue,
                    '\n' => {
                        // Blank line: carries nothing.
                        leading = 0;
                        mixed = false;
                        lines += 1;
                        if (lines >= DETECT_LINES) break :outer;
                        continue;
                    },
                    else => {
                        at_line_start = false;
                        if (leading == 0) {
                            prev_spaces = 0;
                        } else if (first == '\t') {
                            tab_lines += 1;
                        } else if (!mixed and b != '*') {
                            space_lines += 1;
                            const d = if (leading > prev_spaces) leading - prev_spaces else prev_spaces - leading;
                            if (d > 1 and d < steps.len) steps[d] += 1;
                            prev_spaces = leading;
                        }
                    },
                }
            }
            if (b == '\n') {
                at_line_start = true;
                leading = 0;
                mixed = false;
                lines += 1;
                if (lines >= DETECT_LINES) break :outer;
            }
        }
    }
    if (tab_lines == 0 and space_lines == 0) return null;
    if (tab_lines > space_lines) return .{ .style = .tabs };
    // Preference on ties: the common widths first.
    const order = [_]u16{ 4, 2, 8, 3, 6, 5, 7 };
    var best: ?u16 = null;
    var best_n: usize = 0;
    for (order) |w| {
        if (steps[w] > best_n) {
            best = w;
            best_n = steps[w];
        }
    }
    return .{ .style = .spaces, .size = best };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;
const Document = @import("document.zig").Document;

fn detectText(text: []const u8) !?Detected {
    var doc = try Document.initFromBytes(testing.allocator, text);
    defer doc.deinit();
    return detect(&doc.rope);
}

test "indentation: detection picks tabs vs the space step" {
    const tabs = (try detectText("all:\n\tcc -o x x.c\n\tstrip x\n")).?;
    try testing.expectEqual(Style.tabs, tabs.style);

    const two = (try detectText("def f():\n  if x:\n    y()\n  return 1\n")).?;
    try testing.expectEqual(Style.spaces, two.style);
    try testing.expectEqual(@as(u16, 2), two.size.?);

    const four = (try detectText(
        \\/**
        \\ * A comment whose continuation lines are one space in.
        \\ */
        \\int main(void) {
        \\    if (x) {
        \\        y();
        \\    }
        \\    return 0;
        \\}
        \\
    )).?;
    try testing.expectEqual(Style.spaces, four.style);
    try testing.expectEqual(@as(u16, 4), four.size.?);

    try testing.expect((try detectText("no indentation\nat all\n\n")) == null);
    try testing.expect((try detectText("")) == null);

    // Majority wins in a mixed file.
    const mostly_tabs = (try detectText("a\n\tb\n\tc\n\td\n    e\n")).?;
    try testing.expectEqual(Style.tabs, mostly_tabs.style);
}

test "indentation: precedence, property by property" {
    // Nothing but config.
    const d = resolve(.{ .config_spaces = true, .config_width = 4 });
    try testing.expectEqual(Style.spaces, d.style);
    try testing.expectEqual(@as(u16, 4), d.size);
    try testing.expectEqual(Source.config, d.source);

    // Content beats config; its step sets the size.
    const det = resolve(.{ .detected = .{ .style = .spaces, .size = 2 }, .config_width = 4 });
    try testing.expectEqual(@as(u16, 2), det.size);
    try testing.expectEqual(Source.detected, det.source);
    try testing.expectEqual(@as(u16, 4), det.tab_width);

    // .editorconfig beats content.
    const ec = resolve(.{
        .ec = .{ .indent_style = .tab, .indent_size = .tab, .tab_width = 8 },
        .detected = .{ .style = .spaces, .size = 2 },
    });
    try testing.expectEqual(Style.tabs, ec.style);
    try testing.expectEqual(@as(u16, 8), ec.tab_width);
    try testing.expectEqual(Source.editorconfig, ec.source);

    // A language that requires tabs beats .editorconfig.
    const mk = resolve(.{ .tabs = .require, .ec = .{ .indent_style = .space, .indent_size = .{ .cols = 4 } } });
    try testing.expectEqual(Style.tabs, mk.style);
    try testing.expectEqual(Source.language, mk.source);

    // A preference only beats config, not content.
    const go_det = resolve(.{ .tabs = .prefer, .detected = .{ .style = .spaces, .size = 4 } });
    try testing.expectEqual(Style.spaces, go_det.style);
    const go_new = resolve(.{ .tabs = .prefer, .config_spaces = true });
    try testing.expectEqual(Style.tabs, go_new.style);

    // The override beats everything and its width is the tab width
    // when it indents with tabs.
    const ov = resolve(.{ .override = .{ .style = .tabs, .width = 3 }, .tabs = .require, .ec = .{ .indent_style = .space } });
    try testing.expectEqual(Style.tabs, ov.style);
    try testing.expectEqual(@as(u16, 3), ov.tab_width);
    try testing.expectEqual(Source.override, ov.source);

    // A width-only override keeps the lower sources' style.
    const wo = resolve(.{ .override = .{ .width = 2 }, .detected = .{ .style = .spaces, .size = 4 } });
    try testing.expectEqual(Style.spaces, wo.style);
    try testing.expectEqual(@as(u16, 2), wo.size);
}

test "indentation: describe reads naturally" {
    var buf: [48]u8 = undefined;
    const s = Settings{ .style = .spaces, .size = 2, .tab_width = 8, .source = .editorconfig };
    try testing.expectEqualStrings("Spaces: 2 (.editorconfig)", s.describe(&buf));
    const t = Settings{ .style = .tabs, .size = 4, .tab_width = 8, .source = .language };
    try testing.expectEqualStrings("Tabs: 8 (language)", t.describe(&buf));
}

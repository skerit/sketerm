//! GTK-free freedesktop .desktop handling: MimeType list matching and
//! Exec field-code substitution for host-side application launches.

const std = @import("std");

/// True when a ';'-separated .desktop MimeType list contains `mime`.
pub fn mimeListContains(list: []const u8, mime: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |m| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, m, " "), mime)) return true;
    }
    return false;
}

/// Substitute a .desktop Exec line's field codes: %f/%F/%u/%U become
/// the single-quoted path; other % codes are dropped; %% = literal %.
pub fn buildHostExecCmd(allocator: std.mem.Allocator, exec: []const u8, path: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var substituted = false;
    while (i < exec.len) : (i += 1) {
        if (exec[i] != '%' or i + 1 >= exec.len) {
            out.append(allocator, exec[i]) catch return null;
            continue;
        }
        i += 1;
        switch (exec[i]) {
            'f', 'F', 'u', 'U' => {
                appendQuoted(&out, allocator, path) catch return null;
                substituted = true;
            },
            '%' => out.append(allocator, '%') catch return null,
            else => {},
        }
    }
    if (!substituted) {
        out.append(allocator, ' ') catch return null;
        appendQuoted(&out, allocator, path) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

pub fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try out.append(allocator, '\'');
    for (path) |ch| {
        if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
}

test "buildHostExecCmd substitutes and quotes field codes" {
    const t = std.testing;
    const a = t.allocator;
    const cmd = buildHostExecCmd(a, "gimp %U", "/tmp/a'b.png").?;
    defer a.free(cmd);
    try t.expectEqualStrings("gimp '/tmp/a'\\''b.png'", cmd);
    const cmd2 = buildHostExecCmd(a, "vlc --no-video %f %i", "/x.mp4").?;
    defer a.free(cmd2);
    try t.expectEqualStrings("vlc --no-video '/x.mp4' ", cmd2);
    // No field code at all: the path appends.
    const cmd3 = buildHostExecCmd(a, "xdg-open", "/f").?;
    defer a.free(cmd3);
    try t.expectEqualStrings("xdg-open '/f'", cmd3);
    // %% stays a literal percent.
    const cmd4 = buildHostExecCmd(a, "prog 100%% %f", "/f").?;
    defer a.free(cmd4);
    try t.expectEqualStrings("prog 100% '/f'", cmd4);
}

test "mimeListContains matches ';'-separated segments" {
    const t = std.testing;
    try t.expect(mimeListContains("image/png;image/jpeg;", "image/png"));
    try t.expect(mimeListContains("image/png;image/jpeg", "IMAGE/JPEG"));
    try t.expect(!mimeListContains("image/png;image/jpeg", "image/jp"));
    try t.expect(!mimeListContains("", "image/png"));
    // Surrounding spaces in a hand-edited .desktop are tolerated.
    try t.expect(mimeListContains("text/plain; image/png ", "image/png"));
}

test "appendQuoted makes any path one shell word" {
    const t = std.testing;
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendQuoted(&out, a, "/tmp/a b;rm -rf /");
    try t.expectEqualStrings("'/tmp/a b;rm -rf /'", out.items);
    out.clearRetainingCapacity();
    // A single quote closes, escapes and reopens; the word never splits.
    try appendQuoted(&out, a, "it's");
    try t.expectEqualStrings("'it'\\''s'", out.items);
}

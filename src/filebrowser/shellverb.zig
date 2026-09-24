//! The file browser verbs that TYPE into the pane's shell (Open in
//! Terminal, Export Selection to Shell, Batch Rename in $EDITOR): when
//! typing is safe, and the exact text typed. Pure (both test roots);
//! `ui/browser/ops.zig` `typeIntoShell` is the one caller that writes.
//!
//! Typing is only right when the shell is on the SAME host as the tab
//! (a remote tab's paths mean nothing to a local shell, and the
//! reverse), when the session is live, and when the shell is not
//! hidden under a full-screen program (alternate screen: vim, less,
//! top), which would receive the keys as commands of its own.

const std = @import("std");

pub const Verdict = enum {
    ok,
    /// The pane's shell runs on another host than the tab's files.
    other_host,
    /// A full-screen program owns the terminal.
    busy,
    /// No live session to type into.
    no_shell,

    pub fn phrase(self: Verdict) []const u8 {
        return switch (self) {
            .ok => "",
            .other_host => "this pane's shell runs on another host than these files",
            .busy => "a full-screen program is running in this pane's shell",
            .no_shell => "this pane has no live shell",
        };
    }
};

fn hostEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// `shell_host` is the browser host identity of the pane's session
/// (`paths.browserHost`), `tab_host` the tab's (null = this machine).
pub fn verdict(live: bool, shell_host: ?[]const u8, tab_host: ?[]const u8, alt_screen: bool) Verdict {
    if (!live) return .no_shell;
    if (!hostEq(shell_host, tab_host)) return .other_host;
    if (alt_screen) return .busy;
    return .ok;
}

pub fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
}

/// A typed line starts with Ctrl+U: whatever half-typed input sat at
/// the prompt is cleared instead of being prefixed to our command.
pub const KILL_LINE = "\x15";

/// `cd '<dir>'`.
pub fn cdLine(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, KILL_LINE ++ "cd ");
    try appendQuoted(&out, allocator, dir);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// `SK_SEL='<first>'; SK_SEL_ALL='<a> <b> ...'` -- the first path,
/// and all of them space-joined inside ONE quoted word.
pub fn exportLine(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, KILL_LINE ++ "SK_SEL=");
    try appendQuoted(&out, allocator, if (paths.len > 0) paths[0] else "");
    try out.appendSlice(allocator, "; SK_SEL_ALL='");
    for (paths, 0..) |p, i| {
        if (i > 0) try out.append(allocator, ' ');
        for (p) |ch| {
            if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
        }
    }
    try out.appendSlice(allocator, "'\n");
    return out.toOwnedSlice(allocator);
}

/// `"${EDITOR:-vi}" '<list>' && touch '<done>'`.
pub fn editorLine(allocator: std.mem.Allocator, list: []const u8, done: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, KILL_LINE ++ "\"${EDITOR:-vi}\" ");
    try appendQuoted(&out, allocator, list);
    try out.appendSlice(allocator, " && touch ");
    try appendQuoted(&out, allocator, done);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

const tst = std.testing;

test "typing needs a live shell on the tab's host with no full-screen program" {
    try tst.expectEqual(Verdict.ok, verdict(true, null, null, false));
    try tst.expectEqual(Verdict.ok, verdict(true, "box", "box", false));
    try tst.expectEqual(Verdict.other_host, verdict(true, null, "box", false));
    try tst.expectEqual(Verdict.other_host, verdict(true, "box", null, false));
    try tst.expectEqual(Verdict.other_host, verdict(true, "a", "b", false));
    try tst.expectEqual(Verdict.busy, verdict(true, null, null, true));
    try tst.expectEqual(Verdict.no_shell, verdict(false, null, null, false));
}

test "typed lines clear the prompt and quote every path" {
    const a = tst.allocator;
    const cd = try cdLine(a, "/d/it's");
    defer a.free(cd);
    try tst.expectEqualStrings("\x15cd '/d/it'\\''s'\n", cd);
    const ex = try exportLine(a, &.{ "/a b", "/c'd" });
    defer a.free(ex);
    try tst.expectEqualStrings("\x15SK_SEL='/a b'; SK_SEL_ALL='/a b /c'\\''d'\n", ex);
    const ed = try editorLine(a, "/t/l.txt", "/t/l.done");
    defer a.free(ed);
    try tst.expectEqualStrings("\x15\"${EDITOR:-vi}\" '/t/l.txt' && touch '/t/l.done'\n", ed);
}

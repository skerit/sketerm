//! Which deferred web calls may run now (`mcp_webjobs`): calls on one
//! tab keep the order they arrived in, calls on different tabs run
//! together. Pure and engine-free: both test roots import it.

const std = @import("std");

/// What a web call addresses, as far as ordering goes.
pub const Scope = union(enum) {
    /// A call that makes its own new tab (`web_open`): no other call
    /// can address that tab before it answers.
    fresh,
    /// One tab, by handle.
    tab: u32,
    /// No handle (the current tab, a label, the profiles): it waits for
    /// every earlier call, and every later call waits for it.
    all,

    /// Two calls that must not overlap: either is `all`, or both name
    /// the same tab.
    pub fn conflicts(a: Scope, b: Scope) bool {
        if (a == .all or b == .all) return true;
        if (a == .tab and b == .tab) return a.tab == b.tab;
        return false;
    }
};

/// The scope of a web call from its tool name and the handle it names.
/// `web_open` always makes a new tab here: headless, `where` never
/// targets an existing one.
pub fn scopeOf(tool: []const u8, handle: ?u32) Scope {
    if (std.mem.eql(u8, tool, "web_open")) return .fresh;
    if (handle) |h| return .{ .tab = h };
    return .all;
}

/// Whether the call at `index` of `scopes` (every unanswered call,
/// oldest first) may start: no earlier unanswered call conflicts.
pub fn mayStart(scopes: []const Scope, index: usize) bool {
    for (scopes[0..index]) |earlier| {
        if (earlier.conflicts(scopes[index])) return false;
    }
    return true;
}

const t = std.testing;

test "calls on different tabs run together; one tab keeps its order" {
    const q = [_]Scope{ .{ .tab = 1 }, .{ .tab = 2 }, .{ .tab = 1 }, .fresh, .{ .tab = 3 } };
    try t.expect(mayStart(&q, 0));
    try t.expect(mayStart(&q, 1));
    try t.expect(!mayStart(&q, 2));
    try t.expect(mayStart(&q, 3));
    try t.expect(mayStart(&q, 4));
}

test "a call without a handle is a barrier both ways" {
    const q = [_]Scope{ .{ .tab = 1 }, .all, .{ .tab = 2 }, .fresh };
    try t.expect(mayStart(&q, 0));
    try t.expect(!mayStart(&q, 1));
    try t.expect(!mayStart(&q, 2));
    try t.expect(!mayStart(&q, 3));
    const first = [_]Scope{ .all, .{ .tab = 9 } };
    try t.expect(mayStart(&first, 0));
    try t.expect(!mayStart(&first, 1));
}

test "scopeOf: web_open is a fresh tab, a handle a tab, anything else all" {
    try t.expectEqual(Scope.fresh, scopeOf("web_open", null));
    try t.expectEqual(Scope.fresh, scopeOf("web_open", 4));
    try t.expectEqual(Scope{ .tab = 4 }, scopeOf("web_wait", 4));
    try t.expectEqual(Scope.all, scopeOf("web_close", null));
}

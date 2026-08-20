//! Tool exposure policy for the MCP server: which of the ~100 tools a
//! given assistant sees and may call.
//!
//! Group and read-only classification are FACTS ON THE TABLE
//! (`mcp_tools.TOOLS`), not a second list: `TOOL_META` below is
//! generated from it, so a tool can never be advertised without a group
//! or grouped without being advertised.
//!
//! Filtering tools/list is presentation, NOT enforcement — tools/call
//! consults the same policy, or a client that learned a name elsewhere
//! would still reach a withheld tool.

const std = @import("std");
const tools = @import("mcp_tools.zig");

/// The group vocabulary lives on the table; re-exported so policy code
/// and its callers keep spelling it `mcpfilter.Group`.
pub const Group = tools.Group;

pub const Meta = struct {
    name: []const u8,
    group: Group,
    /// Can change state outside this server: injects input, writes a file,
    /// spawns or kills a process, opens a socket. Waits and reads are false
    /// even when they block for a long time.
    mutates: bool,
};

/// Policy's view of the tool table, in table order.
pub const TOOL_META: [tools.TOOLS.len]Meta = blk: {
    var arr: [tools.TOOLS.len]Meta = undefined;
    for (tools.TOOLS, 0..) |t, i| {
        arr[i] = .{ .name = t.name, .group = t.group, .mutates = t.mutates };
    }
    break :blk arr;
};

pub fn lookup(name: []const u8) ?Meta {
    const t = tools.find(name) orelse return null;
    return .{ .name = t.name, .group = t.group, .mutates = t.mutates };
}

pub const ParseError = error{
    UnknownTerm,
    EmptyTerm,
};

/// A tool exposure policy, held as the unparsed spec string so it costs no
/// allocation and can be echoed back verbatim in `capabilities`.
///
/// Grammar: comma- or space-separated terms.
///   all              every tool (the default)
///   <group>          every tool in the group
///   <group>:ro       the group's non-mutating tools only
///   <tool>           that one tool
///   -<group>         deny the group
///   -<group>:ro      deny the group's non-mutating tools
///   -<tool>          deny that one tool
///
/// Deny always wins. If the spec contains no allow term the baseline is
/// "everything", so `-run_command,-file_delete` is a pure blocklist; as
/// soon as one allow term appears the baseline flips to "nothing".
pub const Policy = struct {
    spec: []const u8 = "",

    pub const unrestricted: Policy = .{ .spec = "" };

    pub fn isUnrestricted(self: Policy) bool {
        return trim(self.spec).len == 0;
    }

    /// Validate every term up front. A typo like `browzer` would otherwise
    /// silently withhold the whole group, which reads to the assistant as
    /// "sketerm has no browser tools" and is very hard to debug from the
    /// far side. `bad` receives the offending term.
    pub fn validate(spec: []const u8, bad: *[]const u8) ParseError!void {
        var it = TermIter{ .rest = spec };
        while (it.next()) |t| {
            if (t.body.len == 0) {
                bad.* = t.raw;
                return error.EmptyTerm;
            }
            if (std.mem.eql(u8, t.body, "all")) continue;
            if (groupOf(t.body) != null) continue;
            if (lookup(t.body) != null) {
                // `<tool>:ro` is meaningless: a tool's mutability is fixed.
                if (t.ro) {
                    bad.* = t.raw;
                    return error.UnknownTerm;
                }
                continue;
            }
            bad.* = t.raw;
            return error.UnknownTerm;
        }
    }

    pub fn allowsMeta(self: Policy, m: Meta) bool {
        if (m.group == .core) return true;
        if (self.isUnrestricted()) return true;

        var allowed = !self.hasAllowTerm();
        var it = TermIter{ .rest = self.spec };
        while (it.next()) |t| {
            if (!t.matches(m)) continue;
            // Deny is absolute and order-independent: a spec cannot
            // accidentally re-enable something it took away.
            if (t.deny) return false;
            allowed = true;
        }
        return allowed;
    }

    pub fn allows(self: Policy, name: []const u8) bool {
        const m = lookup(name) orelse return self.isUnrestricted();
        return self.allowsMeta(m);
    }

    fn hasAllowTerm(self: Policy) bool {
        var it = TermIter{ .rest = self.spec };
        while (it.next()) |t| {
            if (!t.deny) return true;
        }
        return false;
    }
};

fn groupOf(body: []const u8) ?Group {
    for (std.enums.values(Group)) |g| {
        if (std.mem.eql(u8, body, @tagName(g))) return g;
    }
    return null;
}

const Term = struct {
    raw: []const u8,
    body: []const u8,
    deny: bool,
    ro: bool,

    fn matches(self: Term, m: Meta) bool {
        if (std.mem.eql(u8, self.body, "all")) return true;
        if (groupOf(self.body)) |g| {
            if (g != m.group) return false;
            return !self.ro or !m.mutates;
        }
        return std.mem.eql(u8, self.body, m.name);
    }
};

const TermIter = struct {
    rest: []const u8,

    fn next(self: *TermIter) ?Term {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfAny(u8, self.rest, ", ") orelse self.rest.len;
            const raw = trim(self.rest[0..end]);
            self.rest = if (end == self.rest.len) self.rest[end..] else self.rest[end + 1 ..];
            if (raw.len == 0) continue;

            var body = raw;
            var deny = false;
            if (body[0] == '-' or body[0] == '!') {
                deny = true;
                body = body[1..];
            }
            var is_ro = false;
            if (std.mem.endsWith(u8, body, ":ro")) {
                is_ro = true;
                body = body[0 .. body.len - 3];
            }
            return .{ .raw = raw, .body = body, .deny = deny, .ro = is_ro };
        }
        return null;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// ── tools/list filtering ──────────────────────────────────────────

/// The tools/list array narrowed to what `policy` allows, rebuilt from
/// the table so no JSON has to be re-parsed to find out what a member
/// is called.
pub fn filterToolsJson(arena: std.mem.Allocator, policy: Policy) ![]const u8 {
    if (policy.isUnrestricted()) return tools.TOOLS_JSON;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");

    var wrote: usize = 0;
    for (TOOL_META, tools.TOOL_JSON) |m, json| {
        if (!policy.allowsMeta(m)) continue;
        if (wrote > 0) try w.writeAll(",");
        try w.writeAll(json);
        wrote += 1;
    }

    try w.writeAll("]");
    return aw.written();
}

/// Names of the tools `policy` withholds, for the capabilities report.
pub fn suppressedGroups(policy: Policy, buf: []Group) []Group {
    var n: usize = 0;
    for (std.enums.values(Group)) |g| {
        if (g == .core) continue;
        var any_allowed = false;
        var populated = false;
        for (TOOL_META) |m| {
            if (m.group != g) continue;
            populated = true;
            if (policy.allowsMeta(m)) {
                any_allowed = true;
                break;
            }
        }
        // A group with no tools yet is absent, not withheld.
        if (populated and !any_allowed and n < buf.len) {
            buf[n] = g;
            n += 1;
        }
    }
    return buf[0..n];
}

// ── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "an empty policy allows everything" {
    const p: Policy = .unrestricted;
    try testing.expect(p.allows("run_command"));
    try testing.expect(p.allows("file_delete"));
    try testing.expect(p.isUnrestricted());
}

test "one allow term flips the baseline to deny" {
    const p: Policy = .{ .spec = "app" };
    try testing.expect(p.allows("app_click"));
    try testing.expect(p.allows("screenshot_app"));
    try testing.expect(!p.allows("run_command"));
    try testing.expect(!p.allows("file_delete"));
}

test "a pure blocklist keeps everything else" {
    const p: Policy = .{ .spec = "-run_command, -file_delete" };
    try testing.expect(!p.allows("run_command"));
    try testing.expect(!p.allows("file_delete"));
    try testing.expect(p.allows("file_read"));
    try testing.expect(p.allows("app_click"));
}

test "the ro suffix drops a group's mutating tools" {
    const p: Policy = .{ .spec = "app:ro" };
    try testing.expect(p.allows("screenshot_app"));
    try testing.expect(p.allows("app_a11y_tree"));
    try testing.expect(!p.allows("app_click"));
    try testing.expect(!p.allows("app_type"));
    try testing.expect(!p.allows("launch_app"));
}

test "deny wins over an allow in either order" {
    const a: Policy = .{ .spec = "files, -file_delete_tree" };
    try testing.expect(a.allows("file_read"));
    try testing.expect(!a.allows("file_delete_tree"));

    const b: Policy = .{ .spec = "-file_delete_tree, files" };
    try testing.expect(b.allows("file_read"));
    try testing.expect(!b.allows("file_delete_tree"));
}

test "a single tool can be allowed out of an otherwise denied group" {
    const p: Policy = .{ .spec = "app:ro, file_read" };
    try testing.expect(p.allows("file_read"));
    try testing.expect(!p.allows("file_write"));
    try testing.expect(p.allows("screenshot_app"));
}

test "capabilities survives every policy" {
    try testing.expect((Policy{ .spec = "app" }).allows("capabilities"));
    try testing.expect((Policy{ .spec = "-all" }).allows("capabilities"));
    try testing.expect((Policy{ .spec = "-capabilities" }).allows("capabilities"));
}

test "validate rejects a typo and names it" {
    var bad: []const u8 = "";
    try testing.expectError(error.UnknownTerm, Policy.validate("app, browzer", &bad));
    try testing.expectEqualStrings("browzer", bad);

    try testing.expectError(error.UnknownTerm, Policy.validate("-notatool", &bad));
    try testing.expectEqualStrings("-notatool", bad);

    // :ro on a single tool is a category error, not a no-op.
    try testing.expectError(error.UnknownTerm, Policy.validate("app_click:ro", &bad));

    try Policy.validate("all", &bad);
    try Policy.validate("app:ro, -app_backtrace, browser, file_read", &bad);
    try Policy.validate("", &bad);
}

test "filterToolsJson emits only the allowed tools, schemas intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try filterToolsJson(arena, .{ .spec = "app:ro" });
    // Still one JSON line: the framing survives the rebuild.
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    try testing.expect(parsed.value.array.items.len > 0);
    try testing.expect(parsed.value.array.items.len < tools.TOOLS.len);

    var saw_read = false;
    var saw_core = false;
    for (parsed.value.array.items) |item| {
        const nm = item.object.get("name").?.string;
        // Nothing withheld leaked through, in either direction.
        try testing.expect((Policy{ .spec = "app:ro" }).allows(nm));
        try testing.expect(item.object.get("inputSchema").?.object.get("properties") != null);
        if (std.mem.eql(u8, nm, "screenshot_app")) saw_read = true;
        if (std.mem.eql(u8, nm, "capabilities")) saw_core = true;
        if (std.mem.eql(u8, nm, "app_click") or std.mem.eql(u8, nm, "run_command"))
            return error.WithheldToolLeaked;
    }
    try testing.expect(saw_read);
    // core survives every policy.
    try testing.expect(saw_core);
    // A nested schema travelled verbatim, quotes and braces included.
    try testing.expect(std.mem.indexOf(u8, out, "\"inputSchema\":{\"type\":\"object\"") != null);
}

test "an unrestricted policy hands back the generated list unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try filterToolsJson(arena_state.allocator(), .unrestricted);
    try testing.expectEqualStrings(tools.TOOLS_JSON, out);
}

test "a policy denying everything still lists core" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try filterToolsJson(arena, .{ .spec = "-all" });
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try testing.expectEqualStrings("capabilities", parsed.value.array.items[0].object.get("name").?.string);
}

test "TOOL_META mirrors the table exactly" {
    try testing.expectEqual(tools.TOOLS.len, TOOL_META.len);
    for (TOOL_META, tools.TOOLS) |m, t| {
        try testing.expectEqualStrings(t.name, m.name);
        try testing.expectEqual(t.group, m.group);
        try testing.expectEqual(t.mutates, m.mutates);
        const l = lookup(t.name).?;
        try testing.expectEqualStrings(t.name, l.name);
        try testing.expectEqual(t.group, l.group);
    }
    try testing.expect(lookup("no_such_tool") == null);
}

test "suppressedGroups names the groups an assistant cannot reach" {
    var buf: [8]Group = undefined;
    const out = suppressedGroups(.{ .spec = "app:ro" }, &buf);
    // app keeps its read-only half, so every other populated group is
    // withheld. core is always on.
    try testing.expectEqualSlices(Group, &.{ .panes, .term, .files, .net, .browser, .ui }, out);

    // ui is populated now, so it can be asked for on its own — and is
    // then the ONLY group that survives.
    const only_ui = suppressedGroups(.{ .spec = "ui" }, &buf);
    try testing.expectEqualSlices(Group, &.{ .panes, .app, .term, .files, .net, .browser }, only_ui);
    try testing.expect((Policy{ .spec = "ui" }).allows("ui_show"));
    try testing.expect(!(Policy{ .spec = "ui" }).allows("run_command"));
    // ui:ro keeps the two reads and drops the writes, including the
    // destructive one.
    try testing.expect((Policy{ .spec = "ui:ro" }).allows("ui_wait_event"));
    try testing.expect((Policy{ .spec = "ui:ro" }).allows("ui_panels"));
    try testing.expect(!(Policy{ .spec = "ui:ro" }).allows("ui_delete"));
    try testing.expect(!(Policy{ .spec = "ui:ro" }).allows("ui_show"));

    const none = suppressedGroups(.unrestricted, &buf);
    try testing.expectEqual(@as(usize, 0), none.len);
}

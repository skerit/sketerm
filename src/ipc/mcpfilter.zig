//! Tool exposure policy for the MCP server: which of the ~100 tools a
//! given assistant sees and may call.
//!
//! Group and read-only classification live here as typed Zig rather than
//! as extra fields inside TOOLS_JSON, so the payload sent to clients stays
//! a pure MCP document. A test in mcp.zig cross-checks the two lists, which
//! is the only real risk: a tool added to one and not the other.
//!
//! Filtering tools/list is presentation, NOT enforcement — tools/call
//! consults the same policy, or a client that learned a name elsewhere
//! would still reach a withheld tool.

const std = @import("std");

pub const Group = enum {
    /// Tabs and panes of a running GUI.
    panes,
    /// Forwarded Wayland apps (launch, drive, screenshot).
    app,
    /// Daemon-owned headless terminals (term_*).
    term,
    /// File operations and transfers.
    files,
    /// Port forwarding.
    net,
    /// Browser automation over CDP.
    browser,
    /// Agent-authored UI panels.
    ui,
    /// Always exposed regardless of policy.
    core,

    pub fn name(self: Group) []const u8 {
        return @tagName(self);
    }
};

pub const Meta = struct {
    name: []const u8,
    group: Group,
    /// Can change state outside this server: injects input, writes a file,
    /// spawns or kills a process, opens a socket. Waits and reads are false
    /// even when they block for a long time.
    mutates: bool,
};

fn ro(n: []const u8, g: Group) Meta {
    return .{ .name = n, .group = g, .mutates = false };
}

fn rw(n: []const u8, g: Group) Meta {
    return .{ .name = n, .group = g, .mutates = true };
}

pub const TOOL_META = [_]Meta{
    // ── panes: the running GUI's tabs and panes ────────────────────
    ro("list_terminals", .panes),
    ro("read_screen", .panes),
    ro("screenshot_pane", .panes),
    rw("record_pane_start", .panes),
    rw("record_pane_stop", .panes),
    rw("send_text", .panes),
    rw("send_keys", .panes),
    rw("run_command", .panes),
    ro("wait_idle", .panes),
    rw("new_tab", .panes),
    rw("split_pane", .panes),
    rw("focus_pane", .panes),
    rw("close_pane", .panes),

    // ── app: forwarded Wayland applications ────────────────────────
    ro("list_installed_apps", .app),
    rw("launch_app", .app),
    ro("list_apps", .app),
    ro("app_windows", .app),
    ro("screenshot_app", .app),
    ro("get_app_state", .app),
    ro("app_output", .app),
    ro("app_log", .app),
    ro("app_wait_log", .app),
    rw("app_click", .app),
    rw("app_actions", .app),
    rw("app_mouse_move", .app),
    rw("app_perform_action", .app),
    rw("app_set_value", .app),
    ro("app_wait_for_element", .app),
    rw("app_drag", .app),
    rw("app_type", .app),
    ro("app_clipboard_get", .app),
    rw("app_clipboard_set", .app),
    rw("app_key", .app),
    rw("app_scroll", .app),
    rw("app_resize", .app),
    ro("app_wait", .app),
    ro("app_watch", .app),
    // Sweeps the pointer across the window: input injection, not a read.
    rw("app_hover_map", .app),
    // Attaches a debugger to a live process; can wedge or kill it.
    rw("app_backtrace", .app),
    ro("app_a11y_tree", .app),
    rw("app_record_start", .app),
    rw("app_record_stop", .app),
    ro("app_read_text", .app),
    ro("app_wait_text", .app),
    rw("app_template_save", .app),
    ro("app_templates", .app),
    ro("app_find_image", .app),
    ro("app_wait_image", .app),
    rw("app_macro_save", .app),
    rw("app_macro_run", .app),
    ro("app_macros", .app),
    rw("close_app_window", .app),
    rw("close_app", .app),

    // ── term: headless daemon-owned terminals ──────────────────────
    rw("term_open", .term),
    ro("term_list", .term),
    rw("term_run", .term),
    rw("term_send_text", .term),
    rw("term_send_keys", .term),
    ro("term_read", .term),
    ro("term_wait_idle", .term),
    ro("term_wait_command", .term),
    rw("term_resize", .term),
    rw("term_close", .term),
    rw("term_exec", .term),
    rw("term_exec_wait", .term),
    ro("term_wait_exit", .term),

    // ── files ──────────────────────────────────────────────────────
    rw("upload_file", .files),
    // Writes the copy into the local filesystem.
    rw("download_file", .files),
    ro("file_list", .files),
    ro("file_stat", .files),
    ro("file_read", .files),
    rw("file_write", .files),
    rw("file_mkdir", .files),
    rw("file_rename", .files),
    rw("file_delete", .files),
    rw("file_copy", .files),
    rw("file_delete_tree", .files),
    ro("file_hash", .files),
    rw("file_extract", .files),
    rw("file_archive_create", .files),
    rw("file_trash", .files),
    rw("file_chmod", .files),
    rw("file_truncate", .files),
    ro("file_media_info", .files),
    ro("file_jobs", .files),
    ro("file_job", .files),

    // ── net ────────────────────────────────────────────────────────
    rw("port_forward_open", .net),
    ro("port_forward_list", .net),
    ro("port_forward_check", .net),
    rw("port_forward_close", .net),

    // ── browser ────────────────────────────────────────────────────
    ro("web_tabs", .browser),
    rw("web_open", .browser),
    rw("web_navigate", .browser),
    ro("web_snapshot", .browser),
    rw("web_act", .browser),
    ro("web_expand", .browser),
    ro("web_query", .browser),
    ro("web_read", .browser),
    ro("web_wait", .browser),
    // Moves the page, and a scroll can trigger lazy loads.
    rw("web_scroll", .browser),
    rw("web_eval", .browser),
    ro("web_screenshot", .browser),

    // ── ui: agent-authored panels ──────────────────────────────────
    rw("ui_show", .ui),
    // A document generator over the same show path; still shows.
    rw("ui_show_files", .ui),
    rw("ui_patch", .ui),
    // Waits for the user; changes nothing.
    ro("ui_wait_event", .ui),
    ro("ui_panels", .ui),
    // Writes a document into the user's state dir.
    rw("ui_save", .ui),
    rw("ui_close", .ui),
    // Unlinks a saved document.
    rw("ui_delete", .ui),

    // ── core: never filtered ───────────────────────────────────────
    ro("capabilities", .core),
};

// No group name may collide with a tool name, or a policy term would be
// ambiguous.
comptime {
    @setEvalBranchQuota(20_000);
    for (TOOL_META) |m| {
        for (std.enums.values(Group)) |g| {
            if (std.mem.eql(u8, m.name, @tagName(g)))
                @compileError("tool name collides with a group name: " ++ m.name);
        }
    }
}

pub fn lookup(name: []const u8) ?Meta {
    for (TOOL_META) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
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

/// Rewrite a tools JSON array, keeping only the tools `policy` allows.
///
/// Scans top-level objects by brace depth rather than parsing: the schemas
/// contain nested objects and braces inside strings, and a full parse plus
/// re-serialize would reorder keys and reflow the hand-written payload.
pub fn filterToolsJson(
    arena: std.mem.Allocator,
    tools_json: []const u8,
    policy: Policy,
) ![]const u8 {
    if (policy.isUnrestricted()) return tools_json;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");

    var wrote: usize = 0;
    var it = ObjectIter{ .src = tools_json };
    while (it.next()) |obj| {
        const name = objectName(obj) orelse continue;
        if (!policy.allows(name)) continue;
        if (wrote > 0) try w.writeAll(",");
        try w.writeAll(obj);
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

/// Iterates the top-level `{...}` members of a JSON array.
const ObjectIter = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *ObjectIter) ?[]const u8 {
        while (self.i < self.src.len and self.src[self.i] != '{') : (self.i += 1) {}
        if (self.i >= self.src.len) return null;

        const start = self.i;
        var depth: usize = 0;
        var in_str = false;
        var esc = false;
        while (self.i < self.src.len) : (self.i += 1) {
            const ch = self.src[self.i];
            if (esc) {
                esc = false;
                continue;
            }
            if (in_str) {
                if (ch == '\\') esc = true else if (ch == '"') in_str = false;
                continue;
            }
            switch (ch) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.i += 1;
                        return self.src[start..self.i];
                    }
                },
                else => {},
            }
        }
        return null; // unbalanced; caller gets a short list rather than garbage
    }
};

/// The value of a tool object's top-level "name" key. The key is written
/// first in every entry of TOOLS_JSON, so the first occurrence is it.
fn objectName(obj: []const u8) ?[]const u8 {
    const key = "\"name\":\"";
    const at = std.mem.indexOf(u8, obj, key) orelse return null;
    const rest = obj[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
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

test "filterToolsJson keeps whole objects and fixes the commas" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[{"name":"app_click","inputSchema":{"type":"object","properties":{"x":{"type":"integer"}}}},{"name":"run_command","inputSchema":{"type":"object"}},{"name":"capabilities","inputSchema":{"type":"object"}}]
    ;
    const out = try filterToolsJson(arena, src, .{ .spec = "app" });

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expectEqualStrings("app_click", parsed.value.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("capabilities", parsed.value.array.items[1].object.get("name").?.string);
    // The nested schema travelled verbatim.
    try testing.expect(std.mem.indexOf(u8, out, "\"x\":{\"type\":\"integer\"}") != null);
}

test "filterToolsJson is not confused by braces inside strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[{"name":"app_click","description":"pass {\"x\":1} to it"},{"name":"run_command","description":"a } brace"}]
    ;
    const out = try filterToolsJson(arena, src, .{ .spec = "panes" });
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try testing.expectEqualStrings("run_command", parsed.value.array.items[0].object.get("name").?.string);
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

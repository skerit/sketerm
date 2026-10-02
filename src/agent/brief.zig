//! Brief templates: a named prompt with `{var}` placeholders and optional
//! defaults, stored per user (`ipc/mcpassets.zig`, kind `agent_template`). `{{` and `}}` are literal
//! braces; any other lone brace is refused at save, so a placeholder can
//! never silently render as text.

const std = @import("std");

/// Template text above this is refused.
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
/// Variables per template at most.
pub const MAX_VARS: usize = 32;
/// A variable value above this is refused.
pub const MAX_VALUE_BYTES: usize = 16 * 1024;
/// A description above this is refused.
pub const MAX_DESCRIPTION_BYTES: usize = 1024;

pub const Var = struct {
    name: []const u8,
    /// null: the caller must pass it.
    default: ?[]const u8 = null,
};

pub const Template = struct {
    name: []const u8,
    text: []const u8,
    description: ?[]const u8 = null,
    /// Every placeholder of `text`, in first-use order.
    vars: []const Var = &.{},
};

/// A refusal: the message names what is wrong.
pub const Refusal = struct { msg: []const u8 };

fn validVarName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |ch, i| switch (ch) {
        'a'...'z', 'A'...'Z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

const Piece = union(enum) { lit: []const u8, brace: u8, ph: []const u8 };

/// Split `text` into literals, escaped braces and placeholders.
/// @return a refusal message for a lone brace or a bad placeholder name.
fn scan(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Piece)) !?[]const u8 {
    var i: usize = 0;
    var lit: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch != '{' and ch != '}') {
            i += 1;
            continue;
        }
        if (i > lit) try out.append(arena, .{ .lit = text[lit..i] });
        if (i + 1 < text.len and text[i + 1] == ch) {
            try out.append(arena, .{ .brace = ch });
            i += 2;
        } else if (ch == '}') {
            return try std.fmt.allocPrint(arena, "a lone '}}' at byte {d} of the template: write }}}} for a literal brace", .{i});
        } else {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse
                return try std.fmt.allocPrint(arena, "a '{{' at byte {d} of the template is never closed: write {{{{ for a literal brace", .{i});
            const name = text[i + 1 .. close];
            if (!validVarName(name))
                return try std.fmt.allocPrint(arena, "'{{{s}}}' at byte {d} is not a placeholder (names are letters, digits and _, not starting with a digit): write {{{{ and }}}} for literal braces", .{ name, i });
            try out.append(arena, .{ .ph = name });
            i = close + 1;
        }
        lit = i;
    }
    if (text.len > lit) try out.append(arena, .{ .lit = text[lit..] });
    return null;
}

/// Check a template to save: its text's placeholders, the declared `vars`
/// (name to default string, or null for none) and the description.
/// Returns the template with `vars` in first-use order.
pub fn build(arena: std.mem.Allocator, name: []const u8, text: []const u8, vars: ?std.json.Value, description: ?[]const u8, why: *Refusal) !?Template {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return refuse(why, "text is empty");
    if (text.len > MAX_TEXT_BYTES) return refuse(why, try std.fmt.allocPrint(arena, "text is {d} bytes; at most {d}", .{ text.len, MAX_TEXT_BYTES }));
    if (description) |d| if (d.len > MAX_DESCRIPTION_BYTES) return refuse(why, try std.fmt.allocPrint(arena, "description is {d} bytes; at most {d}", .{ d.len, MAX_DESCRIPTION_BYTES }));
    var pieces: std.ArrayList(Piece) = .empty;
    if (try scan(arena, text, &pieces)) |msg| return refuse(why, msg);
    var list: std.ArrayList(Var) = .empty;
    for (pieces.items) |p| if (p == .ph) {
        if (findVar(list.items, p.ph) == null) try list.append(arena, .{ .name = p.ph });
    };
    if (vars) |v| {
        if (v != .object) return refuse(why, "vars must be an object: variable name to its default (a string, or null for none)");
        var it = v.object.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const i = findVar(list.items, k) orelse
                return refuse(why, try std.fmt.allocPrint(arena, "vars declares '{s}' but the text has no {{{s}}} placeholder", .{ k, k }));
            switch (kv.value_ptr.*) {
                .null => {},
                .string => |d| {
                    if (d.len > MAX_VALUE_BYTES) return refuse(why, try std.fmt.allocPrint(arena, "the default of '{s}' is longer than {d} bytes", .{ k, MAX_VALUE_BYTES }));
                    list.items[i].default = d;
                },
                else => return refuse(why, try std.fmt.allocPrint(arena, "the default of '{s}' must be a string (or null for none)", .{k})),
            }
        }
    }
    if (list.items.len > MAX_VARS) return refuse(why, try std.fmt.allocPrint(arena, "the text uses {d} variables; at most {d}", .{ list.items.len, MAX_VARS }));
    return .{ .name = name, .text = text, .description = description, .vars = list.items };
}

fn refuse(why: *Refusal, msg: []const u8) ?Template {
    why.* = .{ .msg = msg };
    return null;
}

fn findVar(list: []const Var, name: []const u8) ?usize {
    for (list, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) return i;
    return null;
}

/// Render `tpl` with `given` (name to string value); a missing variable
/// without a default, or an unknown one passed, is refused by name.
pub fn render(arena: std.mem.Allocator, tpl: Template, given: ?std.json.Value, why: *Refusal) !?[]const u8 {
    if (given) |g| {
        if (g != .object) {
            why.* = .{ .msg = "vars must be an object: variable name to its value (a string)" };
            return null;
        }
        var it = g.object.iterator();
        while (it.next()) |kv| {
            if (findVar(tpl.vars, kv.key_ptr.*) == null) {
                why.* = .{ .msg = try std.fmt.allocPrint(arena, "template '{s}' has no variable '{s}' (it has: {s})", .{ tpl.name, kv.key_ptr.*, try varNames(arena, tpl.vars) }) };
                return null;
            }
            if (kv.value_ptr.* != .string) {
                why.* = .{ .msg = try std.fmt.allocPrint(arena, "variable '{s}' must be a string", .{kv.key_ptr.*}) };
                return null;
            }
            if (kv.value_ptr.*.string.len > MAX_VALUE_BYTES) {
                why.* = .{ .msg = try std.fmt.allocPrint(arena, "variable '{s}' is longer than {d} bytes", .{ kv.key_ptr.*, MAX_VALUE_BYTES }) };
                return null;
            }
        }
    }
    var pieces: std.ArrayList(Piece) = .empty;
    if (try scan(arena, tpl.text, &pieces)) |msg| {
        why.* = .{ .msg = msg };
        return null;
    }
    var out: std.ArrayList(u8) = .empty;
    for (pieces.items) |p| switch (p) {
        .lit => |s| try out.appendSlice(arena, s),
        .brace => |b| try out.append(arena, b),
        .ph => |name| {
            const value = blk: {
                if (given) |g| if (g.object.get(name)) |v| break :blk v.string;
                const i = findVar(tpl.vars, name) orelse unreachable;
                break :blk tpl.vars[i].default orelse {
                    why.* = .{ .msg = try std.fmt.allocPrint(arena, "template '{s}' needs variable '{s}' (it has no default): pass it in vars", .{ tpl.name, name }) };
                    return null;
                };
            };
            try out.appendSlice(arena, value);
        },
    };
    return out.items;
}

/// `a, b, c` (or `none`).
pub fn varNames(arena: std.mem.Allocator, vars: []const Var) ![]const u8 {
    if (vars.len == 0) return "none";
    var out: std.ArrayList(u8) = .empty;
    for (vars, 0..) |v, i| try out.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", v.name });
    return out.items;
}

/// The stored form (one JSON object).
pub fn serialize(arena: std.mem.Allocator, tpl: Template) ![]const u8 {
    var vars: std.json.ObjectMap = .empty;
    for (tpl.vars) |v| try vars.put(arena, v.name, if (v.default) |d| .{ .string = d } else .null);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "version", .{ .integer = 1 });
    try obj.put(arena, "name", .{ .string = tpl.name });
    try obj.put(arena, "text", .{ .string = tpl.text });
    if (tpl.description) |d| try obj.put(arena, "description", .{ .string = d });
    try obj.put(arena, "vars", .{ .object = vars });
    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = obj }, .{});
}

/// Read a stored template back, re-checked like a save (a hand-edited file
/// gets the same refusals).
pub fn parseStored(arena: std.mem.Allocator, name: []const u8, bytes: []const u8, why: *Refusal) !?Template {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
        why.* = .{ .msg = try std.fmt.allocPrint(arena, "the stored template '{s}' is not valid JSON", .{name}) };
        return null;
    };
    if (v != .object) return refuse(why, try std.fmt.allocPrint(arena, "the stored template '{s}' is not a JSON object", .{name}));
    const text = if (v.object.get("text")) |x| (if (x == .string) x.string else null) else null;
    const desc = if (v.object.get("description")) |x| (if (x == .string) x.string else null) else null;
    return build(arena, name, text orelse return refuse(why, try std.fmt.allocPrint(arena, "the stored template '{s}' has no text", .{name})), v.object.get("vars"), desc, why);
}

// -- tests --

const t = std.testing;

fn json(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

test "substitution: defaults, escapes, missing and unknown variables" {
    var as = std.heap.ArenaAllocator.init(t.allocator);
    defer as.deinit();
    const a = as.allocator();
    var why: Refusal = undefined;
    const tpl = (try build(a, "fix", "Fix {issue} in {repo}; keep {{braces}} and {issue} twice", try json(a, "{\"repo\":\"sketerm\"}"), "fixes", &why)).?;
    try t.expectEqual(@as(usize, 2), tpl.vars.len);
    try t.expectEqualStrings("issue", tpl.vars[0].name);
    try t.expect(tpl.vars[0].default == null);
    try t.expectEqualStrings("sketerm", tpl.vars[1].default.?);
    try t.expectEqualStrings("Fix #12 in sketerm; keep {braces} and #12 twice", (try render(a, tpl, try json(a, "{\"issue\":\"#12\"}"), &why)).?);
    try t.expectEqualStrings("Fix a in b; keep {braces} and a twice", (try render(a, tpl, try json(a, "{\"issue\":\"a\",\"repo\":\"b\"}"), &why)).?);
    // A value is never re-scanned: braces in it are literal.
    try t.expectEqualStrings("Fix {x} in sketerm; keep {braces} and {x} twice", (try render(a, tpl, try json(a, "{\"issue\":\"{x}\"}"), &why)).?);
    try t.expect(try render(a, tpl, null, &why) == null);
    try t.expectEqualStrings("template 'fix' needs variable 'issue' (it has no default): pass it in vars", why.msg);
    try t.expect(try render(a, tpl, try json(a, "{\"issue\":\"1\",\"branch\":\"x\"}"), &why) == null);
    try t.expectEqualStrings("template 'fix' has no variable 'branch' (it has: issue, repo)", why.msg);
    try t.expect(try render(a, tpl, try json(a, "{\"issue\":1}"), &why) == null);
    try t.expectEqualStrings("variable 'issue' must be a string", why.msg);
}

test "templates refuse lone braces, bad names and undeclared vars" {
    var as = std.heap.ArenaAllocator.init(t.allocator);
    defer as.deinit();
    const a = as.allocator();
    var why: Refusal = undefined;
    const cases = [_]struct { text: []const u8, vars: ?[]const u8 = null, needle: []const u8 }{
        .{ .text = "json {\"a\":1}", .needle = "is not a placeholder" },
        .{ .text = "open { never", .needle = "is never closed" },
        .{ .text = "close } alone", .needle = "a lone '}'" },
        .{ .text = "{1x}", .needle = "is not a placeholder" },
        .{ .text = "  ", .needle = "text is empty" },
        .{ .text = "hi {a}", .vars = "{\"b\":\"x\"}", .needle = "vars declares 'b' but the text has no {b} placeholder" },
        .{ .text = "hi {a}", .vars = "{\"a\":3}", .needle = "the default of 'a' must be a string" },
    };
    for (cases) |cs| {
        const r = try build(a, "x", cs.text, if (cs.vars) |v| try json(a, v) else null, null, &why);
        try t.expect(r == null);
        if (std.mem.indexOf(u8, why.msg, cs.needle) == null) {
            std.debug.print("'{s}' lacks '{s}'\n", .{ why.msg, cs.needle });
            return error.TestUnexpectedResult;
        }
    }
}

test "the stored form round-trips" {
    var as = std.heap.ArenaAllocator.init(t.allocator);
    defer as.deinit();
    const a = as.allocator();
    var why: Refusal = undefined;
    const tpl = (try build(a, "rev", "Review {pr}, {{strict}}", try json(a, "{\"pr\":null}"), "review a PR", &why)).?;
    const bytes = try serialize(a, tpl);
    try t.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null);
    const back = (try parseStored(a, "rev", bytes, &why)).?;
    try t.expectEqualStrings(tpl.text, back.text);
    try t.expectEqualStrings("review a PR", back.description.?);
    try t.expectEqual(@as(usize, 1), back.vars.len);
    try t.expect(back.vars[0].default == null);
    try t.expect(try parseStored(a, "rev", "{nope", &why) == null);
    try t.expect(try parseStored(a, "rev", "{\"vars\":{}}", &why) == null);
    try t.expectEqualStrings("the stored template 'rev' has no text", why.msg);
}

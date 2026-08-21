//! Emblem rules: name globs and extended attributes to badge icons.
//!
//! Rule-driven rather than a fixed registry (the inventory's lesson
//! from Windows' 15-slot overlay fiasco): every badge comes from a
//! line the user wrote, and the attributes the rules reference are
//! requested with the listing itself, so a badge costs no extra round
//! trip per row.
//!
//! Config: $XDG_CONFIG_HOME/sketerm/emblems.conf, one rule per line
//!
//!   *.zig            = emblem-important-symbolic
//!   attr:user.sketerm.pin        = emblem-favorite-symbolic
//!   attr:user.rating=5           = starred-symbolic
//!
//! An `attr:` rule without `=value` matches whenever the attribute is
//! present; with one it matches that exact value. First match wins,
//! so earlier lines are more specific.

const std = @import("std");
const c = @import("../c.zig").c;
/// Case-insensitive `*`/`?` name glob (same shape as the file-color rules).
const globMatch = @import("../util/glob.zig").matchName;
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

pub const Rule = struct {
    /// Name glob (empty for attribute rules).
    glob: []const u8 = "",
    /// Attribute name, `user.`-namespaced (empty for glob rules).
    attr: []const u8 = "",
    /// Required attribute value; null = "present with any value".
    value: ?[]const u8 = null,
    icon: []const u8,
};

pub const Rules = struct {
    arena: std.heap.ArenaAllocator,
    list: []const Rule = &.{},

    pub fn deinit(self: *Rules) void {
        self.arena.deinit();
    }

    /// Attribute names referenced by the rules, deduped, in order.
    pub fn attrNames(self: *const Rules, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (self.list) |rule| {
            if (rule.attr.len == 0) continue;
            var seen = false;
            for (out[0..n]) |name| {
                if (std.mem.eql(u8, name, rule.attr)) seen = true;
            }
            if (seen or n >= out.len) continue;
            out[n] = rule.attr;
            n += 1;
        }
        return out[0..n];
    }

    /// The icon for one entry. `attrValue` resolves an attribute name
    /// to its value for this entry ("" or null = absent).
    pub fn iconFor(
        self: *const Rules,
        name: []const u8,
        ctx: anytype,
        comptime attrValue: fn (@TypeOf(ctx), []const u8) ?[]const u8,
    ) ?[]const u8 {
        for (self.list) |rule| {
            if (rule.attr.len > 0) {
                const have = attrValue(ctx, rule.attr) orelse continue;
                if (have.len == 0) continue;
                if (rule.value) |want| {
                    if (!std.mem.eql(u8, have, want)) continue;
                }
                return rule.icon;
            }
            if (rule.glob.len > 0 and globMatch(rule.glob, name)) return rule.icon;
        }
        return null;
    }
};

pub fn configPath(buf: []u8) ?[]const u8 {
    if (profile.getenv("XDG_CONFIG_HOME")) |xc|
        return std.fmt.bufPrint(buf, "{s}/sketerm/emblems.conf", .{xc}) catch null;
    if (profile.getenv("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.config/sketerm/emblems.conf", .{home}) catch null;
    return null;
}

/// Load the rules file; an absent or unreadable file means "no
/// emblems", never an error the browser has to handle.
pub fn load(allocator: std.mem.Allocator) Rules {
    var rules = Rules{ .arena = std.heap.ArenaAllocator.init(allocator) };
    var path_buf: [4096]u8 = undefined;
    const path = configPath(&path_buf) orelse return rules;
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return rules;
    const fp = c.fopen(pz, "rb") orelse return rules;
    defer _ = c.fclose(fp);
    var bytes: [64 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0) return rules;
    rules.list = parse(rules.arena.allocator(), bytes[0..n]) catch &.{};
    return rules;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]const Rule {
    var out: std.ArrayList(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.lastIndexOfScalar(u8, line, '=') orelse continue;
        const icon = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const left = std.mem.trim(u8, line[0..eq], " \t");
        if (icon.len == 0 or left.len == 0) continue;
        if (std.mem.startsWith(u8, left, "attr:")) {
            const spec = left["attr:".len..];
            // The FIRST '=' inside the spec separates name from value;
            // the line's last '=' already split off the icon.
            const name_end = std.mem.indexOfScalar(u8, spec, '=') orelse spec.len;
            const name = std.mem.trim(u8, spec[0..name_end], " \t");
            if (!std.mem.startsWith(u8, name, "user.")) continue;
            const value: ?[]const u8 = if (name_end < spec.len)
                try arena.dupe(u8, std.mem.trim(u8, spec[name_end + 1 ..], " \t"))
            else
                null;
            try out.append(arena, .{
                .attr = try arena.dupe(u8, name),
                .value = value,
                .icon = try arena.dupe(u8, icon),
            });
        } else {
            try out.append(arena, .{
                .glob = try arena.dupe(u8, left),
                .icon = try arena.dupe(u8, icon),
            });
        }
    }
    return out.items;
}

test "emblem rules parse globs and attribute predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = try parse(arena.allocator(),
        \\# comment
        \\*.zig = emblem-important-symbolic
        \\attr:user.sketerm.pin = emblem-favorite-symbolic
        \\attr:user.rating=5 = starred-symbolic
        \\attr:security.selinux = nope
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings("*.zig", rules[0].glob);
    try std.testing.expectEqualStrings("emblem-important-symbolic", rules[0].icon);
    try std.testing.expectEqualStrings("user.sketerm.pin", rules[1].attr);
    try std.testing.expect(rules[1].value == null);
    try std.testing.expectEqualStrings("5", rules[2].value.?);
}

test "iconFor prefers the first matching rule and reports its attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = Rules{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .list = try parse(arena.allocator(),
            \\attr:user.rating=5 = starred-symbolic
            \\*.zig = zig-symbolic
            \\* = generic-symbolic
        ),
    };
    var mutable = rules;
    defer mutable.deinit();

    const Lookup = struct {
        rating: ?[]const u8,
        fn get(self: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "user.rating")) return self.rating;
            return null;
        }
    };
    try std.testing.expectEqualStrings(
        "starred-symbolic",
        rules.iconFor("main.zig", Lookup{ .rating = "5" }, Lookup.get).?,
    );
    // A non-matching value falls through to the glob rules.
    try std.testing.expectEqualStrings(
        "zig-symbolic",
        rules.iconFor("main.zig", Lookup{ .rating = "2" }, Lookup.get).?,
    );
    try std.testing.expectEqualStrings(
        "generic-symbolic",
        rules.iconFor("notes.md", Lookup{ .rating = null }, Lookup.get).?,
    );

    var names: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), rules.attrNames(&names).len);
}

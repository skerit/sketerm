//! `sketerm motion install|list|remove|record`: managing installed
//! motion packs. Recording opens the GTK trainer, which `main.zig`
//! starts from the parsed request; everything else is here, GTK-free.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pack_mod = @import("pack.zig");
const store = @import("store.zig");

pub const USAGE =
    \\Usage: sketerm motion record [--name NAME] [--out FILE]
    \\       sketerm motion install FILE [--name NAME]
    \\       sketerm motion list
    \\       sketerm motion remove NAME
    \\
    \\Motion packs are YOUR recorded pointer reaches, typing rhythm and
    \\scrolling, replayed by the headless browser for web_act / web_scroll
    \\with motion:"replay" (sketerm mcp --web-motion-pack NAME, or config
    \\web_motion_pack). `record` opens the trainer window, the only way a
    \\pack is made; Ctrl+S there installs it, complete or not. When NAME
    \\(default my-<device>) is already installed the window offers to
    \\continue it, so a pack can be recorded over several sittings; an
    \\unsaved recording is autosaved as a draft in
    \\$XDG_STATE_HOME/sketerm/ and offered back next time. Packs live in
    \\$XDG_DATA_HOME/sketerm/motion-packs/ and are private (0600).
    \\
    \\A pack is one person's motor behaviour: sharing it shares a
    \\biometric, and using one pack for many unrelated accounts links
    \\those accounts behaviourally.
    \\
;

pub const Request = union(enum) {
    help,
    list,
    install: struct { path: []const u8, name: ?[]const u8 = null },
    remove: []const u8,
    record: struct { name: []const u8 = "", out: ?[]const u8 = null },
    bad: []const u8,
};

pub fn parse(args: []const []const u8) Request {
    if (args.len == 0) return .help;
    const verb = args[0];
    const rest = args[1..];
    for (rest) |a| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) return .help;
    if (std.mem.eql(u8, verb, "list")) return if (rest.len == 0) .list else .{ .bad = "list takes no arguments" };
    if (std.mem.eql(u8, verb, "remove")) {
        if (rest.len != 1) return .{ .bad = "remove takes one pack NAME" };
        return .{ .remove = rest[0] };
    }
    if (std.mem.eql(u8, verb, "install")) {
        var req: Request = .{ .install = .{ .path = "" } };
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--name")) {
                if (i + 1 >= rest.len) return .{ .bad = "--name needs a value" };
                i += 1;
                req.install.name = rest[i];
            } else if (req.install.path.len == 0) {
                req.install.path = rest[i];
            } else return .{ .bad = "install takes one FILE" };
        }
        if (req.install.path.len == 0) return .{ .bad = "install needs a pack FILE" };
        return req;
    }
    if (std.mem.eql(u8, verb, "record")) {
        var req: Request = .{ .record = .{} };
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (i + 1 >= rest.len) return .{ .bad = "record: --name and --out need a value" };
            if (std.mem.eql(u8, rest[i], "--name")) {
                req.record.name = rest[i + 1];
                if (!pack_mod.validName(req.record.name)) return .{ .bad = "a pack name is 1-64 characters of a-z, 0-9, '_' or '-'" };
            } else if (std.mem.eql(u8, rest[i], "--out")) {
                req.record.out = rest[i + 1];
            } else return .{ .bad = "record takes --name NAME and --out FILE" };
            i += 1;
        }
        return req;
    }
    return .{ .bad = "unknown motion command" };
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = c.fputs(s.ptr, platform.stdout());
}

fn complain(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "sketerm motion: " ++ fmt ++ "\n", args) catch return 1;
    _ = c.fputs(s.ptr, platform.stderr());
    return 1;
}

fn describe(s: pack_mod.Pack.Summary) [200]u8 {
    var buf: [200]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buf, "{s}, {d:.0} Hz, {d} reaches, {d} key timings, {d} scroll bursts, {d} idle segments ({d} replayable as drift)", .{ @tagName(s.device), s.rate_hz, s.reaches, s.keys, s.scroll, s.idle, s.drift }) catch {};
    return buf;
}

/// Every verb but `record`, which the caller runs (it needs GTK).
pub fn run(gpa: std.mem.Allocator, req: Request) u8 {
    switch (req) {
        .help => {
            _ = c.fputs(USAGE, platform.stdout());
            return 0;
        },
        .bad => |why| {
            _ = complain("{s}", .{why});
            _ = c.fputs(USAGE, platform.stderr());
            return 2;
        },
        .record => return complain("record needs the GUI build", .{}),
        .list => {
            const entries = store.list(gpa) catch |err| return complain("cannot list packs ({s})", .{@errorName(err)});
            defer store.freeList(gpa, entries);
            if (entries.len == 0) {
                var d: [4096]u8 = undefined;
                say("no motion packs installed (in {s}); record one with `sketerm motion record`\n", .{store.dir(&d) orelse "?"});
                return 0;
            }
            for (entries) |e| {
                if (e.summary) |s| {
                    const line = describe(s);
                    say("{s}\t{s}\n", .{ e.name, std.mem.sliceTo(&line, 0) });
                } else say("{s}\tINVALID: {s}\n", .{ e.name, e.why });
            }
            return 0;
        },
        .remove => |name| {
            store.remove(name) catch |err| return switch (err) {
                error.InvalidName => complain("'{s}' is not a pack name", .{name}),
                else => complain("no installed pack named '{s}'", .{name}),
            };
            say("removed motion pack '{s}'\n", .{name});
            return 0;
        },
        .install => |in| {
            const name = in.name orelse store.defaultName(in.path);
            var diag: pack_mod.Diag = .{};
            const s = store.install(gpa, in.path, name, &diag) catch |err| return switch (err) {
                error.Invalid => complain("{s} is not a valid motion pack: {s}", .{ in.path, diag.msg() }),
                error.InvalidName => complain("'{s}' is not a usable pack name (1-64 of a-z, 0-9, '_', '-'); pass --name", .{name}),
                error.ReadFailed => complain("cannot read {s}", .{in.path}),
                else => complain("install failed ({s})", .{@errorName(err)}),
            };
            const line = describe(s);
            say("installed motion pack '{s}': {s}\n", .{ name, std.mem.sliceTo(&line, 0) });
            return 0;
        },
    }
}

test "motion command lines parse into requests and refuse the rest" {
    const t = std.testing;
    try t.expect(parse(&.{}) == .help);
    try t.expect(parse(&.{"list"}) == .list);
    try t.expect(parse(&.{ "list", "x" }) == .bad);
    try t.expectEqualStrings("p", parse(&.{ "remove", "p" }).remove);
    const inst = parse(&.{ "install", "/tmp/a.json", "--name", "mine" }).install;
    try t.expectEqualStrings("/tmp/a.json", inst.path);
    try t.expectEqualStrings("mine", inst.name.?);
    try t.expect(parse(&.{"install"}) == .bad);
    const rec = parse(&.{ "record", "--name", "desk", "--out", "/tmp/p.json" }).record;
    try t.expectEqualStrings("desk", rec.name);
    try t.expectEqualStrings("/tmp/p.json", rec.out.?);
    try t.expect(parse(&.{ "record", "--name", "../x" }) == .bad);
    try t.expect(parse(&.{ "record", "--help" }) == .help);
    try t.expect(parse(&.{"dance"}) == .bad);
}

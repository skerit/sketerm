//! Build-time lint: reject `errdefer` inside a function that cannot
//! return an error.
//!
//! Zig accepts `errdefer` in a `void`/`?T`/plain-value function, compiles
//! it without a warning, and then NEVER RUNS IT: only an error return
//! triggers an errdefer, and such a function has no error return. Every
//! `catch return` / `orelse return` inside one silently skips the rollback,
//! so the "cleanup" reads as correct and leaks. A tree-wide sweep in
//! 2026-08 found 22 of these, several in the daemon, one user-triggerable
//! on the first `DECSET ?1049h` under memory pressure.
//!
//! This is an AST check, not a grep: `std.zig.Ast` is the same parser the
//! compiler uses, so comments, strings, `test` blocks, nested functions and
//! `if (builtin...)`-disabled code are classified exactly rather than
//! guessed at.
//!
//! A function "can return an error" when its return type is an error union
//! (`E!T`), an inferred error set (`!T`), or `anyerror`. `errdefer` outside
//! any function body — a `test` block, which always may return an error —
//! is not reported.
//!
//! Honest limits:
//!   - A generic return type (`fn f(comptime T: type) T` where `T` is later
//!     an error union) is unresolvable lexically and would be reported. No
//!     such function exists in the tree; if one appears, give it an explicit
//!     error union rather than weakening this check.
//!   - Reachability is out of scope: an `errdefer` in an error-returning
//!     function whose every failure path is `catch return` is equally dead,
//!     and this tool cannot see that.
//!   - `noreturn` functions are reported, which is correct — their errdefer
//!     is dead for the same reason.
//!
//! `zig build lint-errdefer`, and a dependency of `test` / `test-core` /
//! `test-web`. `--self-check` runs the classifier over embedded fixtures.

const std = @import("std");
const Ast = std.zig.Ast;

/// One reportable site.
const Site = struct {
    line: usize,
    col: usize,
    fn_name: []const u8,
    ret: []const u8,
};

/// True when `node`'s return type admits an error return.
fn returnsError(tree: Ast, proto: Ast.full.FnProto) bool {
    const rt = proto.ast.return_type.unwrap() orelse return false;
    // `E!T` — the parser builds an explicit error_union node.
    if (tree.nodeTag(rt) == .error_union) return true;
    // `!T` — inferred error set: no node of its own, just a `!` token
    // sitting immediately before the return type.
    const first = tree.firstToken(rt);
    if (first > 0 and tree.tokenTag(first - 1) == .bang) return true;
    // `anyerror` on its own is an error set, so `return err` is legal.
    return std.mem.eql(u8, std.mem.trim(u8, tree.getNodeSource(rt), " \t\r\n"), "anyerror");
}

/// Collect every dead-errdefer site in `source`.
fn scanSource(gpa: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList(Site)) !bool {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return false;

    // fn_decl spans, so an errdefer can be attributed to the INNERMOST
    // enclosing function rather than an outer one that happens to error.
    const Fn = struct { first: Ast.TokenIndex, last: Ast.TokenIndex, errors: bool, name: []const u8, ret: []const u8 };
    var fns: std.ArrayList(Fn) = .empty;
    defer fns.deinit(gpa);

    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(n) != .fn_decl) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, n) orelse continue;
        const ret = if (proto.ast.return_type.unwrap()) |rt| tree.getNodeSource(rt) else "";
        try fns.append(gpa, .{
            .first = tree.firstToken(n),
            .last = tree.lastToken(n),
            .errors = returnsError(tree, proto),
            .name = if (proto.name_token) |t| tree.tokenSlice(t) else "<anonymous>",
            .ret = ret,
        });
    }

    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(n) != .@"errdefer") continue;
        const tok = tree.nodeMainToken(n);
        // Innermost enclosing fn = the containing one with the latest start.
        var best: ?Fn = null;
        for (fns.items) |f| {
            if (tok < f.first or tok > f.last) continue;
            if (best == null or f.first > best.?.first) best = f;
        }
        const f = best orelse continue; // test block / comptime: may error.
        if (f.errors) continue;
        const loc = tree.tokenLocation(0, tok);
        try out.append(gpa, .{
            .line = loc.line + 1,
            .col = loc.column + 1,
            .fn_name = f.name,
            .ret = if (f.ret.len == 0) "void" else f.ret,
        });
    }
    return true;
}

const Fixture = struct { src: [:0]const u8, expect: usize };

const fixtures = [_]Fixture{
    .{ .src = "fn a() void { errdefer {} }", .expect = 1 },
    .{ .src = "fn a() !void { errdefer {} }", .expect = 0 },
    .{ .src = "fn a() anyerror!void { errdefer {} }", .expect = 0 },
    .{ .src = "fn a() anyerror { errdefer {} }", .expect = 0 },
    .{ .src = "fn a() E.Error!void { errdefer {} }", .expect = 0 },
    .{ .src = "fn a() error{X}!u8 { errdefer {} }", .expect = 0 },
    .{ .src = "fn a() ?*T { errdefer {} }", .expect = 1 },
    .{ .src = "fn a() callconv(.c) void { errdefer {} }", .expect = 1 },
    .{ .src = "pub fn a(x: u8) u8 { errdefer {} }", .expect = 1 },
    // Nested: attribution is to the innermost function, either way round.
    .{ .src = "fn a() !void { const b = struct { fn c() void { errdefer {} } }; }", .expect = 1 },
    .{ .src = "fn a() void { const b = struct { fn c() !void { errdefer {} } }; }", .expect = 0 },
    // A test block may always return an error.
    .{ .src = "test \"x\" { errdefer {} }", .expect = 0 },
    // Comments and strings are not code.
    .{ .src = "fn a() void { // errdefer {}\n }", .expect = 0 },
    .{ .src = "fn a() void { const s = \"errdefer x\"; _ = s; }", .expect = 0 },
    // Payload form.
    .{ .src = "fn a() void { errdefer |e| _ = e; }", .expect = 1 },
};

fn selfCheck(gpa: std.mem.Allocator) !u8 {
    var bad: u8 = 0;
    for (fixtures, 0..) |f, i| {
        var sites: std.ArrayList(Site) = .empty;
        defer sites.deinit(gpa);
        const parsed = try scanSource(gpa, f.src, &sites);
        if (!parsed) {
            std.debug.print("FAIL: fixture {d} did not parse: {s}\n", .{ i, f.src });
            bad = 1;
            continue;
        }
        if (sites.items.len != f.expect) {
            std.debug.print("FAIL: fixture {d} expected {d} site(s), got {d}: {s}\n", .{ i, f.expect, sites.items.len, f.src });
            bad = 1;
        }
    }
    if (bad == 0) std.debug.print("PASS: errdefer classifier self-check, {d} fixtures\n", .{fixtures.len});
    return bad;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv0

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--self-check")) return selfCheck(gpa);
        try roots.append(gpa, a);
    }
    if (roots.items.len == 0) try roots.append(gpa, "src");

    var found: usize = 0;
    var scanned: usize = 0;
    var unparsed: usize = 0;
    for (roots.items) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const source = try dir.readFileAllocOptions(io, entry.path, gpa, .limited(64 << 20), .of(u8), 0);
            defer gpa.free(source);
            var sites: std.ArrayList(Site) = .empty;
            defer sites.deinit(gpa);
            const parsed = try scanSource(gpa, source, &sites);
            scanned += 1;
            if (!parsed) {
                unparsed += 1;
                std.debug.print("WARN: {s}/{s} did not parse; skipped\n", .{ root, entry.path });
                continue;
            }
            for (sites.items) |s| {
                found += 1;
                std.debug.print(
                    "{s}/{s}:{d}:{d}: errdefer in fn {s}() -> {s}, which cannot return an error (dead cleanup)\n",
                    .{ root, entry.path, s.line, s.col, s.fn_name, s.ret },
                );
            }
        }
    }

    if (found != 0) {
        std.debug.print(
            "FAIL: {d} dead errdefer site(s). Give the function an error return, or do the cleanup explicitly on the catch path and delete the errdefer.\n",
            .{found},
        );
        return 1;
    }
    std.debug.print("PASS: no dead errdefer in {d} Zig files ({d} unparsed)\n", .{ scanned, unparsed });
    return 0;
}

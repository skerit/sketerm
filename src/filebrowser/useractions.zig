//! User actions: `$XDG_CONFIG_HOME/sketerm/actions/*.action` files the
//! file browser offers in its context menu. Pure parsing, matching and
//! command expansion (both test roots); `ui/browser/menu.zig`
//! `appendActionItems` reads the files and runs the result.
//!
//! ```
//! Name=Extract here
//! Exec=tar -xf %f -C %d
//! Ext=tar,tgz              # any of these extensions (case-insensitive)
//! Match=*.tar.*            # basename glob (* and ?), any target
//! Kind=file                # file | dir | any (default any)
//! Selection=single         # single | multiple | any (default any)
//! Hosts=any                # local | remote | any
//! RunsOnHost=true          # run on the file's host as an app session
//! ```
//!
//! Every condition must hold for EVERY target (a multi-selection
//! offers an action only if each selected entry qualifies). `Hosts`
//! defaults to `local` for a plain action -- a local command cannot
//! reach a remote path -- and to `any` for a RunsOnHost one, which is
//! exactly the behaviour of files written before these keys existed.
//!
//! Tokens in Exec, each substituted shell-quoted:
//!   %f  the first target's path        %F  every target's path
//!   %n  the first target's basename    %d  the first target's folder
//!   %h  the host ("" on this machine)  %%  a literal %

const std = @import("std");

pub const Kind = enum { any, file, dir };
pub const Selection = enum { any, single, multiple };
pub const Hosts = enum { local, remote, any };

pub const Action = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    exts: []const u8 = "",
    match: []const u8 = "",
    kind: Kind = .any,
    selection: Selection = .any,
    hosts: ?Hosts = null,
    runs_on_host: bool = false,

    pub fn effectiveHosts(self: Action) Hosts {
        return self.hosts orelse if (self.runs_on_host) .any else .local;
    }
};

pub const Target = struct {
    path: []const u8,
    is_dir: bool,
};

/// Parse one .action file. Slices point into `content`. Null when the
/// file names no action (missing Name or Exec).
pub fn parse(content: []const u8) ?Action {
    var a: Action = .{};
    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Name")) a.name = val;
        if (std.mem.eql(u8, key, "Exec")) a.exec = val;
        if (std.mem.eql(u8, key, "Ext")) a.exts = val;
        if (std.mem.eql(u8, key, "Match")) a.match = val;
        if (std.mem.eql(u8, key, "RunsOnHost")) a.runs_on_host = std.ascii.eqlIgnoreCase(val, "true");
        if (std.mem.eql(u8, key, "Kind")) a.kind = std.meta.stringToEnum(Kind, val) orelse a.kind;
        if (std.mem.eql(u8, key, "Selection")) a.selection = std.meta.stringToEnum(Selection, val) orelse a.selection;
        if (std.mem.eql(u8, key, "Hosts")) a.hosts = std.meta.stringToEnum(Hosts, val) orelse a.hosts;
    }
    if (a.name.len == 0 or a.exec.len == 0) return null;
    return a;
}

/// Case-insensitive glob over a basename: `*` any run, `?` one byte.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n]))) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn extMatches(exts: []const u8, path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";
    var it = std.mem.tokenizeScalar(u8, exts, ',');
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " "), ext)) return true;
    }
    return false;
}

/// Whether `a` is offered for `targets` on a local or remote tab.
pub fn applies(a: Action, targets: []const Target, remote: bool) bool {
    if (targets.len == 0) return false;
    switch (a.effectiveHosts()) {
        .local => if (remote) return false,
        .remote => if (!remote) return false,
        .any => {},
    }
    switch (a.selection) {
        .any => {},
        .single => if (targets.len != 1) return false,
        .multiple => if (targets.len < 2) return false,
    }
    for (targets) |t| {
        switch (a.kind) {
            .any => {},
            .file => if (t.is_dir) return false,
            .dir => if (!t.is_dir) return false,
        }
        if (a.exts.len > 0 and !extMatches(a.exts, t.path)) return false;
        if (a.match.len > 0 and !globMatch(a.match, std.fs.path.basename(t.path))) return false;
    }
    return true;
}

pub fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
}

/// Substitute the tokens of `exec` for `targets` (non-empty).
pub fn expand(allocator: std.mem.Allocator, exec: []const u8, targets: []const Target, host: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const first = targets[0].path;
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] != '%' or i + 1 >= exec.len) {
            try out.append(allocator, exec[i]);
            continue;
        }
        i += 1;
        switch (exec[i]) {
            'f' => try appendQuoted(&out, allocator, first),
            'F' => for (targets, 0..) |t, k| {
                if (k > 0) try out.append(allocator, ' ');
                try appendQuoted(&out, allocator, t.path);
            },
            'n' => try appendQuoted(&out, allocator, std.fs.path.basename(first)),
            'd' => try appendQuoted(&out, allocator, std.fs.path.dirname(first) orelse "/"),
            'h' => try appendQuoted(&out, allocator, host),
            '%' => try out.append(allocator, '%'),
            else => {
                try out.append(allocator, '%');
                try out.append(allocator, exec[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

const tst = std.testing;

test "an old action file keeps its meaning" {
    const a = parse("Name=Open\nExec=xdg-open %f\nExt=png, JPG\n").?;
    try tst.expectEqual(Hosts.local, a.effectiveHosts());
    const png = [_]Target{.{ .path = "/p/a.PNG", .is_dir = false }};
    try tst.expect(applies(a, &png, false));
    try tst.expect(!applies(a, &png, true));
    const txt = [_]Target{.{ .path = "/p/a.txt", .is_dir = false }};
    try tst.expect(!applies(a, &txt, false));
    const on_host = parse("Name=X\nExec=x %f\nRunsOnHost=true\n").?;
    try tst.expect(applies(on_host, &txt, true));
    try tst.expect(parse("Exec=x\n") == null);
}

test "conditions: kind, selection count, glob and hosts" {
    const a = parse("# comment\nName=Pack\nExec=tar -cf out.tar %F\nKind=dir\nSelection=multiple\nHosts=any\n").?;
    const two_dirs = [_]Target{ .{ .path = "/p/a", .is_dir = true }, .{ .path = "/p/b", .is_dir = true } };
    const one_dir = [_]Target{.{ .path = "/p/a", .is_dir = true }};
    const mixed = [_]Target{ .{ .path = "/p/a", .is_dir = true }, .{ .path = "/p/f", .is_dir = false } };
    try tst.expect(applies(a, &two_dirs, true));
    try tst.expect(!applies(a, &one_dir, false));
    try tst.expect(!applies(a, &mixed, false));
    const g = parse("Name=Extract\nExec=tar -xf %f\nMatch=*.tar.*\nSelection=single\n").?;
    try tst.expect(applies(g, &[_]Target{.{ .path = "/p/x.TAR.gz", .is_dir = false }}, false));
    try tst.expect(!applies(g, &[_]Target{.{ .path = "/p/x.tgz", .is_dir = false }}, false));
    const r = parse("Name=R\nExec=r\nHosts=remote\n").?;
    try tst.expect(!applies(r, &one_dir, false));
    try tst.expect(applies(r, &one_dir, true));
    try tst.expect(globMatch("a?c*", "abcdef"));
    try tst.expect(!globMatch("a?c", "abcd"));
}

test "tokens expand shell-quoted" {
    const a = tst.allocator;
    const targets = [_]Target{ .{ .path = "/p/it's.txt", .is_dir = false }, .{ .path = "/p/b c", .is_dir = false } };
    const out = try expand(a, "cmd %f|%F|%n|%d|%h|100%%|%x", &targets, "srv");
    defer a.free(out);
    try tst.expectEqualStrings("cmd '/p/it'\\''s.txt'|'/p/it'\\''s.txt' '/p/b c'|'it'\\''s.txt'|'/p'|'srv'|100%|%x", out);
}

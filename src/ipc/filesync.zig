//! `file_sync`'s engine: path and exclude rules, the local walk, the
//! remote manifest and its diff, the tar stream with its control file, and
//! every script and argv the tool runs. No I/O beyond the local tree and
//! the scratch files, so it is unit-tested in both roots; the MCP handler
//! (`mcp_term.fileSyncTool`) only runs what this builds.

const std = @import("std");
const c = @import("../c.zig").c;
const globMatch = @import("../editor/editorconfig.zig").globMatch;
const shellquote = @import("../util/shellquote.zig");
const filehash = @import("../util/filehash.zig");
const platform = @import("../util/platform.zig");
const pathZ = @import("../util/pathz.zig").pathZ;

const Allocator = std.mem.Allocator;

pub const MAX_EXCLUDES = 64;
pub const MAX_PATTERN = 256;
/// Most local entries one sync walks.
pub const MAX_ENTRIES = 100_000;
/// The staging directory a tar-mode apply extracts into, inside the target.
pub const STAGE_PREFIX = ".sketerm-sync-";

pub const Method = enum { rsync, tar };
pub const Verification = enum { rsync_checksum, sha256_manifest, none };

// ── paths ─────────────────────────────────────────────────────────

pub const Normalized = union(enum) { ok: []const u8, refused: []const u8 };

/// A target path as the scripts use it: absolute, or `./x` relative to the
/// remote login directory; `/`, the home itself, `..` and empty are refused.
pub fn normalizeTarget(arena: Allocator, raw: []const u8, local: bool, home: ?[]const u8) !Normalized {
    const p = std.mem.trim(u8, raw, " \t");
    if (p.len == 0) return .{ .refused = "the target path is empty" };
    if (std.mem.indexOfAny(u8, p, "\n\r\x00") != null) return .{ .refused = "the target path contains a control character" };
    var rest = p;
    var absolute = false;
    var from_home = false;
    if (std.mem.eql(u8, p, "~") or std.mem.startsWith(u8, p, "~/")) {
        from_home = true;
        rest = if (p.len > 1) p[2..] else "";
    } else if (p[0] == '/') {
        absolute = true;
    } else if (p[0] == '~') {
        return .{ .refused = "~user paths are not supported; use an absolute path or ~/..." };
    }
    var out: std.ArrayList(u8) = .empty;
    var segs: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return .{ .refused = "the target path must not contain '..'" };
        try out.append(arena, '/');
        try out.appendSlice(arena, seg);
        segs += 1;
    }
    if (segs == 0) return .{ .refused = if (absolute) "refusing to sync into / itself" else "refusing to sync into the home directory itself" };
    if (absolute) return .{ .ok = out.items };
    if (local) {
        if (!from_home) return .{ .refused = "a local target path must be absolute (or ~/...)" };
        const h = home orelse return .{ .refused = "no HOME to resolve ~/ against" };
        return .{ .ok = try std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, h, "/"), out.items }) };
    }
    return .{ .ok = try std.fmt.allocPrint(arena, ".{s}", .{out.items}) };
}

/// Whether two local paths nest (either inside the other, or equal).
pub fn pathsNest(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "/");
    const y = std.mem.trimEnd(u8, b, "/");
    if (std.mem.eql(u8, x, y)) return true;
    const inside = struct {
        fn f(inner: []const u8, outer: []const u8) bool {
            return inner.len > outer.len and std.mem.startsWith(u8, inner, outer) and inner[outer.len] == '/';
        }
    }.f;
    return inside(x, y) or inside(y, x);
}

// ── excludes ──────────────────────────────────────────────────────

/// rsync-style exclude patterns: no `/` = any final component, a leading
/// `/` anchors at the synced root, any other `/` matches at a directory
/// boundary, a trailing `/` matches directories only; `*` stays inside one
/// component, `**` crosses them.
pub const Exclude = struct {
    pats: []const []const u8 = &.{},

    /// @return a refusal sentence for an unusable pattern, else null.
    pub fn check(pat: []const u8) ?[]const u8 {
        if (pat.len == 0) return "an exclude pattern is empty";
        if (pat.len > MAX_PATTERN) return "an exclude pattern is longer than 256 bytes";
        if (std.mem.indexOfAny(u8, pat, "\n\r\x00") != null) return "an exclude pattern contains a control character";
        if (std.mem.eql(u8, pat, "/")) return "an exclude pattern of '/' would exclude everything";
        return null;
    }

    pub fn matches(self: Exclude, rel: []const u8, is_dir: bool) bool {
        for (self.pats) |raw| {
            var pat = raw;
            if (pat.len > 1 and pat[pat.len - 1] == '/') {
                if (!is_dir) continue;
                pat = pat[0 .. pat.len - 1];
            }
            if (pat[0] == '/') {
                if (globMatch(pat[1..], rel)) return true;
                continue;
            }
            if (std.mem.indexOfScalar(u8, pat, '/') == null and std.mem.indexOf(u8, pat, "**") == null) {
                if (globMatch(pat, std.fs.path.basenamePosix(rel))) return true;
                continue;
            }
            if (globMatch(pat, rel)) return true;
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
                if (globMatch(pat, rel[slash + 1 ..])) return true;
            }
        }
        return false;
    }

    /// `matches` for `rel` or any directory above it.
    pub fn covers(self: Exclude, rel: []const u8, is_dir: bool) bool {
        if (self.matches(rel, is_dir)) return true;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
            if (self.matches(rel[0..slash], true)) return true;
        }
        return false;
    }
};

// ── the local tree ────────────────────────────────────────────────

pub const Kind = enum(u8) {
    file = 'F',
    dir = 'D',
    link = 'L',
    other = 'O',
};

pub const Entry = struct {
    rel: []const u8,
    kind: Kind,
    mtime: i64 = 0,
    size: u64 = 0,
    mode: u32 = 0o644,
    /// Content hash of a file; of `target ++ "\n"` for a link (what the
    /// remote `readlink | sha256sum` produces).
    sha: [64]u8 = @splat('-'),
    link: []const u8 = "",
};

pub const Walk = struct {
    entries: []Entry,
    /// Sockets, fifos and devices: never synced.
    unsupported: usize = 0,
    /// Names with a newline: rsync carries them, a manifest cannot.
    newline_names: usize = 0,

    pub fn count(self: Walk, kind: Kind) usize {
        var n: usize = 0;
        for (self.entries) |e| n += @intFromBool(e.kind == kind);
        return n;
    }

    pub fn find(self: Walk, rel: []const u8) ?*const Entry {
        const i = std.sort.binarySearch(Entry, self.entries, rel, struct {
            fn f(key: []const u8, e: Entry) std.math.Order {
                return std.mem.order(u8, key, e.rel);
            }
        }.f) orelse return null;
        return &self.entries[i];
    }
};

fn lessByRel(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

/// Walk `root` without following any symlink (links are entries, never
/// descended into), skipping what `ex` covers; `hash` computes file hashes.
pub fn walkLocal(arena: Allocator, root: []const u8, ex: Exclude, hash: bool) !Walk {
    var entries: std.ArrayList(Entry) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    var walk: Walk = .{ .entries = &.{} };
    try stack.append(arena, "");
    while (stack.pop()) |dir_rel| {
        const dir_abs = if (dir_rel.len == 0) root else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, dir_rel });
        var zbuf: [4096]u8 = undefined;
        const d = c.opendir(try pathZ(&zbuf, dir_abs)) orelse return error.Unreadable;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (std.mem.indexOfScalar(u8, name, '\n') != null) {
                walk.newline_names += 1;
                continue;
            }
            const rel = if (dir_rel.len == 0) try arena.dupe(u8, name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, name });
            const abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
            var st: c.struct_stat = undefined;
            if (c.lstat(try pathZ(&zbuf, abs), &st) != 0) return error.Unreadable;
            const fmt = st.st_mode & c.S_IFMT;
            const kind: Kind = if (fmt == c.S_IFREG) .file else if (fmt == c.S_IFDIR) .dir else if (fmt == c.S_IFLNK) .link else .other;
            if (ex.matches(rel, kind == .dir)) continue;
            if (kind == .other) {
                walk.unsupported += 1;
                continue;
            }
            if (entries.items.len >= MAX_ENTRIES) return error.TooManyEntries;
            var e: Entry = .{ .rel = rel, .kind = kind, .mtime = platform.mtimeSecs(&st), .mode = @intCast(st.st_mode & 0o7777) };
            switch (kind) {
                .file => {
                    e.size = @intCast(@max(st.st_size, 0));
                    if (hash) e.sha = (filehash.sha256File(abs) orelse return error.Unreadable).hex;
                },
                .link => {
                    var lbuf: [4096]u8 = undefined;
                    const n = c.readlink(try pathZ(&zbuf, abs), &lbuf, lbuf.len);
                    if (n < 0) return error.Unreadable;
                    e.link = try arena.dupe(u8, lbuf[0..@intCast(n)]);
                    e.sha = hexSha(try std.fmt.allocPrint(arena, "{s}\n", .{e.link}));
                },
                .dir => try stack.append(arena, rel),
                .other => unreachable,
            }
            try entries.append(arena, e);
        }
    }
    std.mem.sort(Entry, entries.items, {}, lessByRel);
    walk.entries = entries.items;
    return walk;
}

pub fn hexSha(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ── the remote manifest and its diff ──────────────────────────────

pub const Remote = struct { kind: Kind, mtime: i64, sha: []const u8 };

/// What the inspect script reported about one target.
pub const Inspect = struct {
    existed: bool = false,
    refused: ?[]const u8 = null,
    err: ?[]const u8 = null,
    manifest: std.StringHashMapUnmanaged(Remote) = .empty,
};

/// Parse the inspect script's output (`SKI_*` lines, then the manifest
/// between `SKM_BEGIN` and `SKM_END` when one was asked for).
pub fn parseInspect(arena: Allocator, out: []const u8, want_manifest: bool) !Inspect {
    var r: Inspect = .{};
    var in_manifest = false;
    var ended = false;
    var saw_state = false;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (in_manifest) {
            if (std.mem.eql(u8, line, "SKM_END")) {
                in_manifest = false;
                ended = true;
                continue;
            }
            const e = parseManifestLine(line) orelse {
                r.err = try std.fmt.allocPrint(arena, "the remote manifest has a line it cannot carry (an unreadable file, or a name with a newline): {s}", .{line});
                return r;
            };
            if (std.mem.startsWith(u8, e.rel, STAGE_PREFIX)) continue;
            try r.manifest.put(arena, try arena.dupe(u8, e.rel), .{ .kind = e.kind, .mtime = e.mtime, .sha = try arena.dupe(u8, e.sha) });
            continue;
        }
        if (std.mem.eql(u8, line, "SKI_EXISTS")) {
            r.existed = true;
            saw_state = true;
        } else if (std.mem.eql(u8, line, "SKI_ABSENT")) {
            saw_state = true;
        } else if (std.mem.eql(u8, line, "SKI_NOTDIR")) {
            r.refused = "the target exists and is not a directory";
        } else if (std.mem.eql(u8, line, "SKI_ROOT")) {
            r.refused = "the target resolves to / itself";
        } else if (std.mem.eql(u8, line, "SKI_HOME")) {
            r.refused = "the target resolves to the home directory itself";
        } else if (std.mem.startsWith(u8, line, "SKI_ERR:")) {
            r.err = try std.fmt.allocPrint(arena, "inspecting the target failed: {s}", .{inspectErr(line["SKI_ERR:".len..])});
        } else if (std.mem.eql(u8, line, "SKM_BEGIN")) {
            in_manifest = true;
        }
    }
    if (r.refused != null or r.err != null) return r;
    if (!saw_state) r.err = "the target could not be inspected (no answer from the remote script)";
    if (want_manifest and r.existed and !ended) r.err = "the remote manifest was cut short";
    return r;
}

fn inspectErr(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "mkdir")) return "cannot create the target directory";
    if (std.mem.eql(u8, code, "cd")) return "cannot enter the target directory";
    if (std.mem.eql(u8, code, "nosha")) return "no sha256sum, shasum or sha256 on the host, so tar mode cannot verify";
    return code;
}

const ManifestLine = struct { kind: Kind, mtime: i64, sha: []const u8, rel: []const u8 };

/// `K mtime sha rel`; the path is the rest of the line.
fn parseManifestLine(line: []const u8) ?ManifestLine {
    if (line.len < 7 or line[1] != ' ') return null;
    const kind = std.enums.fromInt(Kind, line[0]) orelse return null;
    var rest = line[2..];
    const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const mtime = std.fmt.parseInt(i64, rest[0..sp1], 10) catch return null;
    rest = rest[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const sha = rest[0..sp2];
    const rel = rest[sp2 + 1 ..];
    if (rel.len == 0 or rel[0] == '/') return null;
    var segs = std.mem.splitScalar(u8, rel, '/');
    while (segs.next()) |s| if (s.len == 0 or std.mem.eql(u8, s, "..") or std.mem.eql(u8, s, ".")) return null;
    const hashed = kind == .file or kind == .link;
    if (hashed and (sha.len != 64 or !isHex(sha))) return null;
    if (!hashed and !std.mem.eql(u8, sha, "-")) return null;
    return .{ .kind = kind, .mtime = mtime, .sha = sha, .rel = rel };
}

fn isHex(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

pub const Plan = struct {
    mkdirs: []const []const u8 = &.{},
    /// Local entries (files and links) to send.
    send: []const *const Entry = &.{},
    deletes: []const []const u8 = &.{},
    skipped_equal: usize = 0,
    skipped_newer: usize = 0,
    conflicts: []const []const u8 = &.{},
    bytes: u64 = 0,

    pub fn skipped(self: Plan) usize {
        return self.skipped_equal + self.skipped_newer;
    }

    pub fn empty(self: Plan) bool {
        return self.mkdirs.len == 0 and self.send.len == 0 and self.deletes.len == 0;
    }
};

/// The changes that make `remote` hold `local`: keep-newer skips a file the
/// remote changed later, `delete` removes what local lacks (never what an
/// exclude covers), and a file/directory type clash is a conflict.
pub fn diff(arena: Allocator, local: Walk, remote: *const std.StringHashMapUnmanaged(Remote), ex: Exclude, keep_newer: bool, delete: bool) !Plan {
    var mkdirs: std.ArrayList([]const u8) = .empty;
    var send: std.ArrayList(*const Entry) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    var plan: Plan = .{};
    for (local.entries) |*e| {
        const there = remote.get(e.rel);
        if (there) |r| {
            const r_dir = r.kind == .dir;
            if (r_dir != (e.kind == .dir)) {
                try conflicts.append(arena, try std.fmt.allocPrint(arena, "{s} ({s} here, {s} there)", .{ e.rel, kindWord(e.kind), kindWord(r.kind) }));
                continue;
            }
        }
        switch (e.kind) {
            .dir => if (there == null) try mkdirs.append(arena, e.rel),
            .file => {
                if (there) |r| {
                    if (r.kind == .file and std.mem.eql(u8, r.sha, &e.sha)) {
                        plan.skipped_equal += 1;
                        continue;
                    }
                    if (keep_newer and r.mtime > e.mtime) {
                        plan.skipped_newer += 1;
                        continue;
                    }
                }
                try send.append(arena, e);
                plan.bytes += e.size;
            },
            .link => {
                if (there) |r| if (r.kind == .link and std.mem.eql(u8, r.sha, &e.sha)) {
                    plan.skipped_equal += 1;
                    continue;
                };
                try send.append(arena, e);
            },
            .other => {},
        }
    }
    if (delete) {
        var it = remote.iterator();
        while (it.next()) |kv| {
            const rel = kv.key_ptr.*;
            if (ex.covers(rel, kv.value_ptr.kind == .dir)) continue;
            if (local.find(rel) == null) try deletes.append(arena, rel);
        }
        // Children before their directory: a descendant sorts after it.
        std.mem.sort([]const u8, deletes.items, {}, struct {
            fn f(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, b, a);
            }
        }.f);
    }
    plan.mkdirs = mkdirs.items;
    plan.send = send.items;
    plan.deletes = deletes.items;
    plan.conflicts = conflicts.items;
    return plan;
}

fn kindWord(k: Kind) []const u8 {
    return switch (k) {
        .file => "file",
        .dir => "directory",
        .link => "symlink",
        .other => "special file",
    };
}

// ── the tar stream ────────────────────────────────────────────────

const TarHeader = std.tar.Writer.Header;

/// Write the archive a tar-mode apply extracts: `ctl` (the plan, one
/// action per line) first, then every sent entry under `f/`.
/// @return error.Changed when a file no longer has the size the walk saw.
pub fn writeTar(arena: Allocator, out_path: []const u8, root: []const u8, plan: Plan) !void {
    var zbuf: [4096]u8 = undefined;
    const f = c.fopen(try pathZ(&zbuf, out_path), "wb") orelse return error.Unwritable;
    var ok = false;
    defer {
        _ = c.fclose(f);
        if (!ok) _ = c.unlink(pathZ(&zbuf, out_path) catch unreachable);
    }
    const ctl = try controlFile(arena, plan);
    try tarHeader(f, "ctl", .regular, ctl.len, 0o600, 0, "");
    try fwriteAll(f, ctl);
    try tarPad(f, ctl.len);
    for (plan.send) |e| {
        const name = try std.fmt.allocPrint(arena, "f/{s}", .{e.rel});
        switch (e.kind) {
            .link => try tarHeader(f, name, .symbolic_link, 0, 0o777, e.mtime, e.link),
            .file => {
                try tarHeader(f, name, .regular, e.size, e.mode, e.mtime, "");
                const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, e.rel });
                var sbuf: [4096]u8 = undefined;
                const in = c.fopen(try pathZ(&sbuf, src_path), "rb") orelse return error.Changed;
                defer _ = c.fclose(in);
                var left = e.size;
                var buf: [65536]u8 = undefined;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, buf.len));
                    const n = c.fread(&buf, 1, want, in);
                    if (n == 0) return error.Changed;
                    try fwriteAll(f, buf[0..n]);
                    left -= n;
                }
                try tarPad(f, e.size);
            },
            else => unreachable,
        }
    }
    try fwriteAll(f, &([_]u8{0} ** 1024));
    if (c.fflush(f) != 0) return error.Unwritable;
    ok = true;
}

fn tarHeader(f: *c.FILE, name: []const u8, kind: TarHeader.FileType, size: u64, mode: u32, mtime: i64, link: []const u8) !void {
    var h: TarHeader = .init(kind);
    h.setPath("", name) catch try tarLong(f, .gnu_long_name, name);
    if (link.len > 0) h.setLinkname(link) catch try tarLong(f, .gnu_long_link, link);
    try h.setSize(size);
    try h.setMode(mode);
    try h.setMtime(@intCast(@max(mtime, 0)));
    try h.updateChecksum();
    try fwriteAll(f, std.mem.asBytes(&h));
}

/// A GNU long-name/long-link record (the name NUL-terminated, as GNU tar writes it).
fn tarLong(f: *c.FILE, kind: TarHeader.FileType, text: []const u8) !void {
    var h: TarHeader = .init(kind);
    @memcpy(h.name[0..13], "././@LongLink");
    try h.setSize(text.len + 1);
    try h.updateChecksum();
    try fwriteAll(f, std.mem.asBytes(&h));
    try fwriteAll(f, text);
    try fwriteAll(f, "\x00");
    try tarPad(f, text.len + 1);
}

fn tarPad(f: *c.FILE, size: u64) !void {
    const rem: usize = @intCast(size % 512);
    if (rem == 0) return;
    try fwriteAll(f, (&([_]u8{0} ** 512))[0 .. 512 - rem]);
}

fn fwriteAll(f: *c.FILE, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.Unwritable;
}

/// One action per line, in apply order: `D rel` (mkdir), `V sha mode rel`
/// (verify then move a file), `L rel` (move a link), `X rel` (delete).
pub fn controlFile(arena: Allocator, plan: Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (plan.mkdirs) |d| try out.print(arena, "D {s}\n", .{d});
    for (plan.send) |e| switch (e.kind) {
        .file => try out.print(arena, "V {s} {o} {s}\n", .{ &e.sha, e.mode, e.rel }),
        .link => try out.print(arena, "L {s}\n", .{e.rel}),
        else => unreachable,
    };
    for (plan.deletes) |x| try out.print(arena, "X {s}\n", .{x});
    return out.items;
}

// ── scripts (POSIX sh; the remote ones travel base64 -> sh) ───────

pub fn quoted(arena: Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    try shellquote.appendQuoted(&list, arena, s);
    return list.items;
}

/// `sk_h` (sha256 of stdin, hex only) from whichever tool the host has.
const HASH_FN =
    \\if command -v sha256sum >/dev/null 2>&1; then sk_h() { sha256sum | cut -c1-64; }
    \\elif command -v shasum >/dev/null 2>&1; then sk_h() { shasum -a 256 | cut -c1-64; }
    \\elif command -v sha256 >/dev/null 2>&1; then sk_h() { sha256 -q; }
    \\else sk_h() { return 1; }; SK_NOSHA=1; fi
    \\
;

/// Once per host: does it have a working rsync, and tar?
pub const PROBE_SCRIPT =
    \\if rsync --version 2>/dev/null | grep 'rsync *version' >/dev/null 2>&1; then echo SKP_RSYNC=1; else echo SKP_RSYNC=0; fi
    \\if command -v tar >/dev/null 2>&1; then echo SKP_TAR=1; else echo SKP_TAR=0; fi
    \\echo SKP_DONE
    \\
;

pub const Probe = struct { ok: bool = false, rsync: bool = false, tar: bool = false };

pub fn parseProbe(out: []const u8) Probe {
    return .{
        .ok = std.mem.indexOf(u8, out, "SKP_DONE") != null,
        .rsync = std.mem.indexOf(u8, out, "SKP_RSYNC=1") != null,
        .tar = std.mem.indexOf(u8, out, "SKP_TAR=1") != null,
    };
}

/// Per target: refuse `/` and the home as resolved on the host, report
/// whether the directory existed, create it when `create`, and (tar mode)
/// print the manifest of what is there.
pub fn inspectScript(arena: Allocator, path: []const u8, manifest: bool, create: bool) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.print(arena, "P={s}\n", .{try quoted(arena, path)});
    try s.appendSlice(arena,
        \\H=$(cd ~ 2>/dev/null && pwd -P)
        \\if [ -e "$P" ] && [ ! -d "$P" ]; then echo SKI_NOTDIR; exit 0; fi
        \\if [ -d "$P" ]; then
        \\  R=$(cd "$P" 2>/dev/null && pwd -P)
        \\  [ "$R" = / ] && { echo SKI_ROOT; exit 0; }
        \\  [ -n "$H" ] && [ "$R" = "$H" ] && { echo SKI_HOME; exit 0; }
        \\  echo SKI_EXISTS
        \\else
        \\  echo SKI_ABSENT
        \\
    );
    if (create) try s.appendSlice(arena, "  mkdir -p \"$P\" || { echo SKI_ERR:mkdir; exit 0; }\n");
    try s.appendSlice(arena, "  exit 0\nfi\n");
    if (manifest) {
        try s.appendSlice(arena, HASH_FN);
        try s.appendSlice(arena,
            \\[ -n "${SK_NOSHA:-}" ] && { echo SKI_ERR:nosha; exit 0; }
            \\if stat -c %Y . >/dev/null 2>&1; then sk_m() { stat -c %Y "$1"; }; else sk_m() { stat -f %m "$1"; }; fi
            \\cd "$P" || { echo SKI_ERR:cd; exit 0; }
            \\echo SKM_BEGIN
            \\find . -path './.sketerm-sync-*' -prune -o ! -name . -print | while IFS= read -r p; do
            \\  r=${p#./}
            \\  if [ -L "$p" ]; then echo "L $(sk_m "$p") $(readlink "$p" | sk_h) $r"
            \\  elif [ -d "$p" ]; then echo "D 0 - $r"
            \\  elif [ -f "$p" ]; then echo "F $(sk_m "$p") $(sk_h < "$p") $r"
            \\  else echo "O 0 - $r"; fi
            \\done
            \\echo SKM_END
            \\
        );
    }
    return s.items;
}

/// The tar-mode apply, reading the archive on stdin: extract into a fresh
/// staging dir inside the target, verify EVERY staged file's sha256
/// against the control file before anything lands, then apply in order;
/// keep-newer leaves a destination modified after the staged copy
/// (`find -newer`, the portable test). `self_name` is this script's remote
/// copy in the home (see `selfName`), removed first.
pub fn applyScript(arena: Allocator, path: []const u8, nonce: []const u8, keep_newer: bool, self_name: ?[]const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    if (self_name) |n| try s.print(arena, "rm -f ~/{s}\n", .{n});
    try s.print(arena, "P={s}\nS=\"$P/" ++ STAGE_PREFIX ++ "{s}\"\nK={d}\n", .{ try quoted(arena, path), nonce, @intFromBool(keep_newer) });
    try s.appendSlice(arena, HASH_FN);
    try s.appendSlice(arena,
        \\[ -n "${SK_NOSHA:-}" ] && { echo SKA_ERR:nosha; exit 3; }
        \\mkdir -p "$P" && mkdir "$S" || { echo SKA_ERR:stage; exit 3; }
        \\trap 'rm -rf "$S"' EXIT
        \\(cd "$S" && tar -xf -) || { echo SKA_ERR:tar; exit 4; }
        \\[ -f "$S/ctl" ] || { echo SKA_ERR:ctl; exit 4; }
        \\bad=0
        \\while IFS= read -r l; do
        \\  case $l in
        \\  'V '*) r=${l#V }; s=${r%% *}; r=${r#* }; r=${r#* }
        \\    g=$(sk_h < "$S/f/$r"); [ "$g" = "$s" ] || { echo "SKA_BAD $r"; bad=1; } ;;
        \\  esac
        \\done < "$S/ctl"
        \\[ "$bad" = 0 ] || { echo SKA_ERR:verify; exit 5; }
        \\echo SKA_VERIFIED
        \\while IFS= read -r l; do
        \\  k=${l%% *}; r=${l#* }
        \\  case $k in
        \\  D) [ -d "$P/$r" ] || mkdir -p "$P/$r" || echo "SKA_MVFAIL $r" ;;
        \\  V|L)
        \\    if [ "$k" = V ]; then m=${r#* }; m=${m%% *}; r=${r#* }; r=${r#* }; fi
        \\    d="$P/$r"; src="$S/f/$r"
        \\    if [ -d "$d" ] && [ ! -L "$d" ]; then echo "SKA_CONFLICT $r"; continue; fi
        \\    if [ "$K" = 1 ] && [ "$k" = V ] && [ -e "$d" ] && [ -n "$(find "$d" -prune -newer "$src" 2>/dev/null)" ]; then echo "SKA_KEPT $r"; continue; fi
        \\    [ "$k" = V ] && chmod "$m" "$src"
        \\    if mv -f "$src" "$d"; then echo "SKA_SENT $r"; else echo "SKA_MVFAIL $r"; fi ;;
        \\  X) if [ -d "$P/$r" ] && [ ! -L "$P/$r" ]; then rmdir "$P/$r" 2>/dev/null && echo "SKA_DEL $r"; else rm -f "$P/$r" && echo "SKA_DEL $r"; fi ;;
        \\  esac
        \\done < "$S/ctl"
        \\echo SKA_DONE
        \\
    );
    return s.items;
}

pub const Applied = struct {
    done: bool = false,
    sent: std.ArrayList([]const u8) = .empty,
    kept: usize = 0,
    deleted: usize = 0,
    /// Paths that failed to land (conflict or move failure).
    failed: std.ArrayList([]const u8) = .empty,
    err: ?[]const u8 = null,
};

pub fn parseApply(arena: Allocator, out: []const u8) !Applied {
    var a: Applied = .{};
    var bad: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "SKA_SENT ")) {
            try a.sent.append(arena, line["SKA_SENT ".len..]);
        } else if (std.mem.startsWith(u8, line, "SKA_KEPT ")) {
            a.kept += 1;
        } else if (std.mem.startsWith(u8, line, "SKA_DEL ")) {
            a.deleted += 1;
        } else if (std.mem.startsWith(u8, line, "SKA_CONFLICT ") or std.mem.startsWith(u8, line, "SKA_MVFAIL ")) {
            try a.failed.append(arena, line[std.mem.indexOfScalar(u8, line, ' ').? + 1 ..]);
        } else if (std.mem.startsWith(u8, line, "SKA_BAD ")) {
            try bad.append(arena, line["SKA_BAD ".len..]);
        } else if (std.mem.startsWith(u8, line, "SKA_ERR:")) {
            const code = line["SKA_ERR:".len..];
            a.err = if (std.mem.eql(u8, code, "verify"))
                try std.fmt.allocPrint(arena, "sha256 mismatch on the host for {d} staged file(s) ({s}); nothing was applied", .{ bad.items.len, if (bad.items.len > 0) bad.items[0] else "?" })
            else if (std.mem.eql(u8, code, "stage"))
                "cannot create the target or its staging directory"
            else if (std.mem.eql(u8, code, "tar"))
                "tar could not extract the stream on the host; nothing was applied"
            else if (std.mem.eql(u8, code, "nosha"))
                "no sha256 tool on the host, so the stream cannot be verified"
            else
                try std.fmt.allocPrint(arena, "apply failed: {s}", .{code});
        } else if (std.mem.eql(u8, line, "SKA_DONE")) {
            a.done = true;
        }
    }
    return a;
}

// ── rsync ─────────────────────────────────────────────────────────

/// Join a command for rsync's `-e`, which splits on spaces itself and
/// honours quotes (a doubled quote inside is a literal one), not a shell's
/// backslashes; every word is single-quoted that way.
pub fn rsyncRsh(arena: Allocator, words: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.append(arena, '\'');
        for (w) |ch| {
            if (ch == '\'') try out.append(arena, '\'');
            try out.append(arena, ch);
        }
        try out.append(arena, '\'');
    }
    return out.items;
}

pub const RsyncOpts = struct {
    keep_newer: bool,
    delete: bool,
    dry_run: bool,
    excludes: []const []const u8,
};

/// The rsync argv: `ssh` is the options home's `ssh ...` words (null for a
/// local target) and `dest` the `host:path` or local path.
pub fn rsyncArgv(arena: Allocator, local_dir: []const u8, ssh: ?[]const []const u8, dest: []const u8, o: RsyncOpts) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "rsync", "-rlpt", "-s", "--out-format=%i %n", "--stats" });
    // keep_newer: a file the destination changed later survives; without
    // it, content (not mtime) decides what is sent.
    try argv.append(arena, if (o.keep_newer) "--update" else "--checksum");
    if (o.delete) try argv.append(arena, "--delete");
    if (o.dry_run) try argv.append(arena, "--dry-run");
    for (o.excludes) |e| try argv.append(arena, try std.fmt.allocPrint(arena, "--exclude={s}", .{e}));
    if (ssh) |words| try argv.appendSlice(arena, &.{ "-e", try rsyncRsh(arena, words) });
    try argv.append(arena, try std.fmt.allocPrint(arena, "{s}/", .{std.mem.trimEnd(u8, local_dir, "/")}));
    try argv.append(arena, try std.fmt.allocPrint(arena, "{s}/", .{dest}));
    return argv.items;
}

pub const RsyncCounts = struct {
    sent: usize = 0,
    deleted: usize = 0,
    regular: ?usize = null,
    bytes: ?u64 = null,
    changed: std.ArrayList([]const u8) = .empty,

    pub fn skipped(self: RsyncCounts) ?usize {
        const reg = self.regular orelse return null;
        return reg -| self.sent;
    }
};

/// Count `--out-format=%i %n` lines and read `--stats`.
pub fn parseRsync(arena: Allocator, out: []const u8) !RsyncCounts {
    var r: RsyncCounts = .{};
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "*deleting ")) {
            r.deleted += 1;
            try r.changed.append(arena, try std.fmt.allocPrint(arena, "-{s}", .{std.mem.trimStart(u8, line["*deleting ".len..], " ")}));
        } else if (line.len > 12 and line[11] == ' ' and (std.mem.startsWith(u8, line, "<f") or std.mem.startsWith(u8, line, ">f") or std.mem.startsWith(u8, line, "cL"))) {
            // `<f` = pushed to a remote host, `>f` = a local copy.
            if (line[1] == 'f') r.sent += 1;
            try r.changed.append(arena, line[12..]);
        } else if (std.mem.startsWith(u8, line, "Number of files: ")) {
            if (std.mem.indexOf(u8, line, "reg: ")) |at| r.regular = statNum(line[at + 5 ..]);
        } else if (std.mem.startsWith(u8, line, "Total transferred file size: ")) {
            r.bytes = statNum(line["Total transferred file size: ".len..]);
        }
    }
    return r;
}

/// A `--stats` number ("1,234" included) at the start of `s`.
fn statNum(s: []const u8) ?u64 {
    var v: u64 = 0;
    var any = false;
    for (s) |ch| switch (ch) {
        '0'...'9' => {
            v = v * 10 + (ch - '0');
            any = true;
        },
        ',', '.' => {},
        else => break,
    };
    return if (any) v else null;
}

/// `exec <words> [< in] > out`: the leg's stdout lands in a file, its
/// stderr stays on the terminal for the error report.
pub fn redirectArgv(arena: Allocator, words: []const []const u8, stdin_path: ?[]const u8, out_path: []const u8) ![]const []const u8 {
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(arena, "exec");
    for (words) |w| {
        try cmd.append(arena, ' ');
        try shellquote.appendQuoted(&cmd, arena, w);
    }
    if (stdin_path) |p| {
        try cmd.appendSlice(arena, " < ");
        try shellquote.appendQuoted(&cmd, arena, p);
    }
    try cmd.appendSlice(arena, " > ");
    try shellquote.appendQuoted(&cmd, arena, out_path);
    const argv = try arena.alloc([]const u8, 3);
    argv[0] = "sh";
    argv[1] = "-c";
    argv[2] = cmd.items;
    return argv;
}

/// The home-relative name of an apply script's remote copy; shell-safe,
/// so `~/<name>` needs no quoting in any login shell.
pub fn selfName(arena: Allocator, nonce: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".sk_sync_{s}.sh", .{nonce});
}

/// A remote command line that writes `script` to `~/<name>` and runs it
/// with `sh`, so the script's stdin stays the ssh channel; plain `;`, `>`
/// and `~/` parse in every login shell.
pub fn remoteFileLine(arena: Allocator, script: []const u8, name: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(script.len));
    _ = enc.encode(b64, script);
    return std.fmt.allocPrint(arena, "echo {s} | base64 -d > ~/{s}; sh ~/{s}", .{ b64, name, name });
}

// ── tests ─────────────────────────────────────────────────────────

const t = std.testing;

test "target paths: / , the home, .., empty and relative-local are refused" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    for ([_][]const u8{ "", "  ", "/", "//", "/./", "~", "~/", ".", "./", "a/../b", "~bob/x" }) |p| {
        try t.expect((try normalizeTarget(ar, p, false, "/home/u")) == .refused);
    }
    try t.expectEqualStrings("/srv/docs", (try normalizeTarget(ar, "/srv//docs/", false, null)).ok);
    try t.expectEqualStrings("./docs/x", (try normalizeTarget(ar, "~/docs/x", false, null)).ok);
    try t.expectEqualStrings("./docs", (try normalizeTarget(ar, "docs", false, null)).ok);
    try t.expectEqualStrings("/home/u/docs", (try normalizeTarget(ar, "~/docs", true, "/home/u/")).ok);
    try t.expect((try normalizeTarget(ar, "docs", true, "/home/u")) == .refused);
}

test "local targets that nest with the source are detected" {
    try t.expect(pathsNest("/a/b", "/a/b/"));
    try t.expect(pathsNest("/a/b/c", "/a/b"));
    try t.expect(pathsNest("/a", "/a/b"));
    try t.expect(!pathsNest("/a/bc", "/a/b"));
}

test "excludes follow rsync's component, anchored and directory rules" {
    const ex: Exclude = .{ .pats = &.{ "*.tmp", "/build", "cache/", "doc/*.bak" } };
    try t.expect(ex.matches("x/y.tmp", false));
    try t.expect(ex.matches("build", true));
    try t.expect(!ex.matches("sub/build", true));
    try t.expect(ex.matches("a/cache", true));
    try t.expect(!ex.matches("a/cache", false));
    try t.expect(ex.matches("doc/x.bak", false));
    try t.expect(ex.matches("p/doc/x.bak", false));
    try t.expect(!ex.matches("doc/sub/x.bak", false));
    try t.expect(ex.covers("build/deep/file", false));
    try t.expect(!ex.covers("src/main.zig", false));
    try t.expect(Exclude.check("") != null);
    try t.expect(Exclude.check("/") != null);
    try t.expect(Exclude.check("a\nb") != null);
    try t.expect(Exclude.check("*.o") == null);
}

fn fakeEntry(rel: []const u8, kind: Kind, mtime: i64, content: []const u8) Entry {
    return .{ .rel = rel, .kind = kind, .mtime = mtime, .size = content.len, .sha = if (kind == .dir) @splat('-') else hexSha(content) };
}

test "the diff sends new and changed files, keeps newer ones, deletes only when asked and never excluded" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var entries = [_]Entry{
        fakeEntry("a.txt", .file, 100, "same"),
        fakeEntry("b.txt", .file, 100, "changed here"),
        fakeEntry("c.txt", .file, 100, "older here"),
        fakeEntry("d", .dir, 0, ""),
        fakeEntry("d/new.txt", .file, 100, "new"),
    };
    const local: Walk = .{ .entries = &entries };
    var remote: std.StringHashMapUnmanaged(Remote) = .empty;
    const same = hexSha("same");
    const other = hexSha("other");
    try remote.put(ar, "a.txt", .{ .kind = .file, .mtime = 50, .sha = &same });
    try remote.put(ar, "b.txt", .{ .kind = .file, .mtime = 50, .sha = &other });
    try remote.put(ar, "c.txt", .{ .kind = .file, .mtime = 200, .sha = &other });
    try remote.put(ar, "gone.txt", .{ .kind = .file, .mtime = 1, .sha = &other });
    try remote.put(ar, "keep.log", .{ .kind = .file, .mtime = 1, .sha = &other });
    try remote.put(ar, "old", .{ .kind = .dir, .mtime = 0, .sha = "-" });
    try remote.put(ar, "old/x", .{ .kind = .file, .mtime = 1, .sha = &other });
    const ex: Exclude = .{ .pats = &.{"*.log"} };

    const p = try diff(ar, local, &remote, ex, true, false);
    try t.expectEqual(@as(usize, 2), p.send.len); // b.txt, d/new.txt
    try t.expectEqualStrings("b.txt", p.send[0].rel);
    try t.expectEqualStrings("d/new.txt", p.send[1].rel);
    try t.expectEqual(@as(usize, 1), p.skipped_equal);
    try t.expectEqual(@as(usize, 1), p.skipped_newer);
    try t.expectEqual(@as(usize, 1), p.mkdirs.len);
    try t.expectEqual(@as(usize, 0), p.deletes.len);

    const all = try diff(ar, local, &remote, ex, false, true);
    try t.expectEqual(@as(usize, 3), all.send.len); // c.txt too without keep_newer
    // Deepest first, the excluded log kept.
    try t.expectEqual(@as(usize, 3), all.deletes.len);
    try t.expectEqualStrings("old/x", all.deletes[0]);
    try t.expectEqualStrings("old", all.deletes[1]);
    try t.expectEqualStrings("gone.txt", all.deletes[2]);
}

test "a file/directory clash is a conflict, not an overwrite" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var entries = [_]Entry{fakeEntry("x", .file, 1, "f")};
    var remote: std.StringHashMapUnmanaged(Remote) = .empty;
    try remote.put(ar, "x", .{ .kind = .dir, .mtime = 0, .sha = "-" });
    const p = try diff(ar, .{ .entries = &entries }, &remote, .{}, true, false);
    try t.expectEqual(@as(usize, 1), p.conflicts.len);
    try t.expectEqual(@as(usize, 0), p.send.len);
}

test "the inspect output parses states, refusals and the manifest" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const sha = "a" ** 64;
    const out = "SKI_EXISTS\nSKM_BEGIN\nF 12 " ++ sha ++ " dir/my file.txt\nD 0 - dir\nL 3 " ++ sha ++ " ln\nF 1 " ++ sha ++ " .sketerm-sync-ab/x\nSKM_END\n";
    const r = try parseInspect(ar, out, true);
    try t.expect(r.err == null and r.refused == null and r.existed);
    try t.expectEqual(@as(u32, 3), r.manifest.count());
    try t.expectEqual(@as(i64, 12), r.manifest.get("dir/my file.txt").?.mtime);
    try t.expect((try parseInspect(ar, "SKI_HOME\n", false)).refused != null);
    try t.expect((try parseInspect(ar, "SKI_ROOT\n", false)).refused != null);
    try t.expect((try parseInspect(ar, "", false)).err != null);
    try t.expect((try parseInspect(ar, "SKI_EXISTS\nSKM_BEGIN\nF 1 " ++ sha ++ " a\n", true)).err != null);
    // A path climbing out of the target is not a manifest line.
    try t.expect((try parseInspect(ar, "SKI_EXISTS\nSKM_BEGIN\nF 1 " ++ sha ++ " ../etc/x\nSKM_END\n", true)).err != null);
    try t.expect((try parseInspect(ar, "SKI_EXISTS\nSKM_BEGIN\nF 1  a\nSKM_END\n", true)).err != null);
}

test "rsync argv: the options home rides -e, keep_newer and delete map to flags, excludes pass through" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ssh = [_][]const u8{ "ssh", "-T", "-o", "ForwardX11=no", "-o", "ProxyCommand=exec /x '%h' '%p'" };
    const argv = try rsyncArgv(ar, "/src/", &ssh, "box:./docs", .{ .keep_newer = true, .delete = false, .dry_run = true, .excludes = &.{"*.tmp"} });
    const joined = try std.mem.join(ar, "\x01", argv);
    try t.expect(std.mem.indexOf(u8, joined, "--update") != null);
    try t.expect(std.mem.indexOf(u8, joined, "--checksum") == null);
    try t.expect(std.mem.indexOf(u8, joined, "--delete") == null);
    try t.expect(std.mem.indexOf(u8, joined, "--dry-run") != null);
    try t.expect(std.mem.indexOf(u8, joined, "--exclude=*.tmp") != null);
    try t.expectEqualStrings("'ssh' '-T' '-o' 'ForwardX11=no' '-o' 'ProxyCommand=exec /x ''%h'' ''%p'''", argv[argv.len - 3]);
    try t.expectEqualStrings("/src/", argv[argv.len - 2]);
    try t.expectEqualStrings("box:./docs/", argv[argv.len - 1]);
    const strict = try rsyncArgv(ar, "/src", null, "/dst", .{ .keep_newer = false, .delete = true, .dry_run = false, .excludes = &.{} });
    const sj = try std.mem.join(ar, "\x01", strict);
    try t.expect(std.mem.indexOf(u8, sj, "--checksum") != null and std.mem.indexOf(u8, sj, "--delete") != null);
    try t.expect(std.mem.indexOf(u8, sj, "-e") == null);
}

test "rsync output: sent, deleted, regular count and bytes" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const out =
        \\cd+++++++++ sub/
        \\<f+++++++++ sub/new.txt
        \\>f.st...... a.txt
        \\*deleting   gone.txt
        \\
        \\Number of files: 6 (reg: 4, dir: 2)
        \\Number of regular files transferred: 2
        \\Total transferred file size: 1,234 bytes
        \\
    ;
    const r = try parseRsync(a.allocator(), out);
    try t.expectEqual(@as(usize, 2), r.sent);
    try t.expectEqual(@as(usize, 1), r.deleted);
    try t.expectEqual(@as(?usize, 4), r.regular);
    try t.expectEqual(@as(?usize, 2), r.skipped());
    try t.expectEqual(@as(?u64, 1234), r.bytes);
}

test "the apply output: sent, kept, deleted, and a verify failure applies nothing" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ok = try parseApply(ar, "SKA_VERIFIED\nSKA_SENT a\nSKA_KEPT b\nSKA_DEL c\nSKA_DONE\n");
    try t.expect(ok.done and ok.err == null);
    try t.expectEqual(@as(usize, 1), ok.sent.items.len);
    try t.expectEqual(@as(usize, 1), ok.kept);
    try t.expectEqual(@as(usize, 1), ok.deleted);
    const bad = try parseApply(ar, "SKA_BAD x\nSKA_ERR:verify\n");
    try t.expect(!bad.done and bad.err != null);
}

test "delete is scoped to the target: the control file only names relative paths under it" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var e = fakeEntry("f.txt", .file, 1, "x");
    e.mode = 0o640;
    const send = [_]*const Entry{&e};
    const ctl = try controlFile(ar, .{ .mkdirs = &.{"d"}, .send = &send, .deletes = &.{"old/x"} });
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "D d\nV {s} 640 f.txt\nX old/x\n", .{&hexSha("x")}), ctl);
    const script = try applyScript(ar, "./docs", "0123abcd", true, try selfName(ar, "0123abcd"));
    try t.expect(std.mem.startsWith(u8, script, "rm -f ~/.sk_sync_0123abcd.sh\nP=./docs\nS=\"$P/.sketerm-sync-0123abcd\"\nK=1\n"));
    // Every destructive command works on "$P/..." only.
    try t.expect(std.mem.indexOf(u8, script, "rm -f \"$P/$r\"") != null);
    try t.expect(std.mem.indexOf(u8, script, "rmdir \"$P/$r\"") != null);
}

test "the tar stream round-trips through std.tar with the control file first" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const td = @import("../util/pathz.zig").TempDir.make("filesync") orelse return error.SkipZigTest;
    defer td.remove();
    const long = "d/" ++ "n" ** 120 ++ ".txt";
    const root = try std.fmt.allocPrint(ar, "{s}/src", .{td.path()});
    var zb: [4096]u8 = undefined;
    _ = c.mkdir(try pathZ(&zb, root), 0o755);
    _ = c.mkdir(try pathZ(&zb, try std.fmt.allocPrint(ar, "{s}/d", .{root})), 0o755);
    for ([_][]const u8{ "a.txt", long }) |rel| {
        const f = c.fopen(try pathZ(&zb, try std.fmt.allocPrint(ar, "{s}/{s}", .{ root, rel })), "wb").?;
        _ = c.fwrite(rel.ptr, 1, rel.len, f);
        _ = c.fclose(f);
    }
    const w = try walkLocal(ar, root, .{}, true);
    try t.expectEqual(@as(usize, 3), w.entries.len);
    var none: std.StringHashMapUnmanaged(Remote) = .empty;
    const plan = try diff(ar, w, &none, .{}, true, false);
    const tar_path = try std.fmt.allocPrint(ar, "{s}/x.tar", .{td.path()});
    try writeTar(ar, tar_path, root, plan);

    var rbuf: [4096]u8 = undefined;
    const f = c.fopen(try pathZ(&rbuf, tar_path), "rb").?;
    var bytes: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try bytes.appendSlice(ar, buf[0..n]);
    }
    _ = c.fclose(f);
    var input: std.Io.Reader = .fixed(bytes.items);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&input, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const first = (try it.next()).?;
    try t.expectEqualStrings("ctl", first.name);
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next()) |entry| try names.append(ar, try ar.dupe(u8, entry.name));
    try t.expectEqual(@as(usize, 2), names.items.len);
    try t.expectEqualStrings("f/a.txt", names.items[0]);
    try t.expectEqualStrings("f/" ++ long, names.items[1]);
}

test "redirectArgv and remoteFileLine keep the script off the remote shell's parser" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const argv = try redirectArgv(ar, &.{ "ssh", "-T", "box", "echo hi; x" }, "/tmp/in.tar", "/tmp/o u t");
    try t.expectEqualStrings("exec ssh -T box 'echo hi; x' < /tmp/in.tar > '/tmp/o u t'", argv[2]);
    const line = try remoteFileLine(ar, "echo 'x'\n", ".sk_sync_1.sh");
    try t.expect(std.mem.indexOfScalar(u8, line, '\'') == null);
    try t.expect(std.mem.endsWith(u8, line, "| base64 -d > ~/.sk_sync_1.sh; sh ~/.sk_sync_1.sh"));
}

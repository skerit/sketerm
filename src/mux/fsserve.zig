//! File-service primitives for the mux daemon (fs_op / fs_delta).
//!
//! Rich directory listings, entry stat, and the inotify watcher that
//! backs live directory VIEWS — a listing is a subscription, not a
//! one-shot reply (docs/filebrowser-roadmap.md, decision 1). View
//! bookkeeping itself lives in daemon.zig (it owns *Client); this
//! module is libc-only, GTK-free, musl-clean, and compiles on macOS
//! (watching degrades to "no live deltas" there until an FSEvents
//! backend exists — Linux is never gated on it).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

const is_linux = builtin.os.tag == .linux;

/// Cap on entries per listing reply chunk: keeps individual fs_reply
/// JSON frames comfortably under ~150KB.
pub const CHUNK_ENTRIES: usize = 512;

/// Hard cap on total entries in one listing (`truncated` past it).
pub const MAX_ENTRIES: usize = 100_000;

/// Largest single fs_op read — clients loop for more. Well under
/// wire.MAX_FRAME with header room.
pub const MAX_READ: usize = 2 << 20;

/// One directory entry on the wire (JSON inside fs_reply/fs_delta).
/// Extending this struct is wire-compatible both ways: JSON readers
/// ignore unknown fields, and absent fields keep their defaults.
pub const Entry = struct {
    name: []const u8,
    /// "file" | "dir" | "link" | "other" — the entry ITSELF (lstat).
    kind: []const u8,
    size: u64 = 0,
    /// Permission bits (mode & 0o7777).
    mode: u32 = 0,
    mtime_ms: i64 = 0,
    mtime_ns: i64 = 0,
    atime_ms: i64 = 0,
    ctime_ms: i64 = 0,
    ctime_ns: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    /// Owner/group NAMES resolved on the owning host ("" when the id
    /// has no passwd/group entry there) -- the daemon resolves them
    /// because only it can answer correctly for remote listings.
    owner: []const u8 = "",
    group: []const u8 = "",
    /// Birth/creation time, 0 when the filesystem cannot report one.
    btime_ms: i64 = 0,
    nlink: u64 = 1,
    blocks: u64 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    /// Symlink target (links only).
    target: ?[]const u8 = null,
    /// True when the entry, links followed, is a directory — the
    /// "can browse into it" signal (true for plain dirs too).
    tdir: bool = false,
    /// Child entry count for directories ("." / ".." excluded), -1
    /// when unknown (non-dirs, permission denied, or a count that hit
    /// CHILD_COUNT_CAP). Counted daemon-side so remote listings get it
    /// without extra round trips.
    children: i64 = -1,
    /// user.sketerm.tags xattr, comma-separated ("" = none; always ""
    /// on platforms without lgetxattr).
    tags: []const u8 = "",
    /// Values for the extended attributes the CLIENT asked for, in
    /// request order; "" means absent. Only present when requested,
    /// so an ordinary listing still costs one lgetxattr per entry.
    attrs: []const []const u8 = &.{},
};

/// One extended attribute of a single file (attr_list replies).
pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

/// Cap on a single attribute value; anything larger is reported
/// truncated rather than streamed through a listing.
pub const MAX_ATTR_VALUE = 4096;

pub fn kindOf(mode: c.mode_t) []const u8 {
    return switch (mode & c.S_IFMT) {
        c.S_IFDIR => "dir",
        c.S_IFREG => "file",
        c.S_IFLNK => "link",
        else => "other",
    };
}

/// Modification time of a stat result in wall-clock milliseconds.
/// Public because every stat-driven job event carries one.
pub fn mtimeMs(st: *const c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

/// Modification time in nanoseconds. The identity an atomic save
/// compares against: millisecond granularity silently merges two
/// edits landing inside the same millisecond.
pub fn mtimeNs(st: *const c.struct_stat) i64 {
    return timespecNs(if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec);
}

fn atimeMs(st: *const c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_atim")) st.st_atim else st.st_atimespec;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn ctimeMs(st: *const c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_ctim")) st.st_ctim else st.st_ctimespec;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

/// uid/gid -> name, memoized: NSS lookups can be arbitrarily slow
/// (LDAP...), and a listing repeats the same handful of ids
/// thousands of times. Single-threaded daemon, so no locking.
const IdNameCache = struct {
    const Slot = struct { id: u32 = 0, used: bool = false, len: u8 = 0, buf: [64]u8 = undefined };
    slots: [32]Slot = @splat(.{}),
    next: usize = 0,

    fn get(self: *IdNameCache, id: u32, comptime lookup: fn (u32) ?[]const u8) []const u8 {
        for (&self.slots) |*s| {
            if (s.used and s.id == id) return s.buf[0..s.len];
        }
        const name = lookup(id) orelse "";
        const s = &self.slots[self.next];
        self.next = (self.next + 1) % self.slots.len;
        const n: u8 = @intCast(@min(name.len, s.buf.len));
        s.* = .{ .id = id, .used = true, .len = n };
        @memcpy(s.buf[0..n], name[0..n]);
        return s.buf[0..n];
    }
};

var uid_names: IdNameCache = .{};
var gid_names: IdNameCache = .{};

fn lookupUser(id: u32) ?[]const u8 {
    const pw = c.getpwuid(id) orelse return null;
    const nm = pw.*.pw_name orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(nm)));
}

fn lookupGroup(id: u32) ?[]const u8 {
    const gr = c.getgrgid(id) orelse return null;
    const nm = gr.*.gr_name orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(nm)));
}

/// Owner name for a uid, "" when it has no passwd entry. The slice
/// points into a rotating cache slot -- dupe it before it outlives
/// the next 32 distinct ids.
pub fn ownerName(uid: u32) []const u8 {
    return uid_names.get(uid, lookupUser);
}

pub fn groupName(gid: u32) []const u8 {
    return gid_names.get(gid, lookupGroup);
}

/// Birth (creation) time in wall-clock ms, 0 when the kernel or the
/// filesystem cannot report one. Linux needs a second syscall
/// (statx); macOS already carries it on the stat result.
fn btimeMsOf(st: *const c.struct_stat, full: [*:0]const u8) i64 {
    if (comptime @hasField(c.struct_stat, "st_birthtimespec")) {
        const ts = st.st_birthtimespec;
        if (ts.tv_sec == 0 and ts.tv_nsec == 0) return 0;
        return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
    } else if (comptime is_linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(
            c.AT_FDCWD,
            full,
            linux.AT.SYMLINK_NOFOLLOW | linux.AT.STATX_DONT_SYNC,
            .{ .BTIME = true },
            &stx,
        );
        // Raw syscall: 0 is success, anything else is -errno.
        if (rc != 0) return 0;
        if (!stx.mask.BTIME) return 0;
        return @as(i64, stx.btime.sec) * 1000 + @as(i64, stx.btime.nsec / 1_000_000);
    }
    return 0;
}

fn timespecNs(ts: c.struct_timespec) i64 {
    const value = @as(i128, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.tv_nsec));
    return @intCast(std.math.clamp(value, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// NUL-join dir + "/" + name into `buf`.
pub fn joinZ(buf: *[4096]u8, dir: []const u8, name: []const u8) pathz.Error![*:0]const u8 {
    if (dir.len + 1 + name.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 .. dir.len + 1 + name.len], name);
    buf[dir.len + 1 + name.len] = 0;
    return @ptrCast(buf);
}

/// A directory with more children than this reports -1 (unknown)
/// rather than a misleading capped number.
pub const CHILD_COUNT_CAP: i64 = 100_000;

/// Count of a directory's entries excluding "." / "..", or -1 when it
/// cannot be opened or exceeds CHILD_COUNT_CAP. Deliberately NOT part
/// of listings (a full readdir per subdirectory made big/networked
/// folders take seconds) — the daemon counts asynchronously after the
/// listing and ships the numbers as view deltas.
pub fn countChildren(path: [*:0]const u8) i64 {
    const d = c.opendir(path) orelse return -1;
    defer _ = c.closedir(d);
    var n: i64 = 0;
    while (c.readdir(d)) |de| {
        const nm: [*:0]const u8 = @ptrCast(&de.*.d_name);
        if (nm[0] == '.' and (nm[1] == 0 or (nm[1] == '.' and nm[2] == 0))) continue;
        n += 1;
        if (n > CHILD_COUNT_CAP) return -1;
    }
    return n;
}

/// Stat one entry (lstat semantics; links resolved just enough for
/// `target`/`tdir`). Strings are duped into `arena`. Null when the
/// entry vanished between readdir and stat — a live filesystem race,
/// not an error. Single-entry stats count children (one readdir);
/// listings must not (see countChildren).
pub fn statEntry(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ?Entry {
    return statEntryAttrs(arena, dir, name, &.{}, true);
}

/// statEntry plus the values of `attrs` (client-requested extended
/// attribute names), in request order.
pub fn statEntryAttrs(arena: std.mem.Allocator, dir: []const u8, name: []const u8, attrs: []const []const u8, count_children: bool) ?Entry {
    var z_buf: [4096]u8 = undefined;
    const full = joinZ(&z_buf, dir, name) catch return null;
    var st: c.struct_stat = undefined;
    if (c.lstat(full, &st) != 0) return null;

    var e: Entry = .{
        .name = arena.dupe(u8, name) catch return null,
        .kind = kindOf(st.st_mode),
        .size = if (st.st_size > 0) @intCast(st.st_size) else 0,
        .mode = @intCast(st.st_mode & 0o7777),
        .mtime_ms = mtimeMs(&st),
        .mtime_ns = timespecNs(if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec),
        .atime_ms = atimeMs(&st),
        .ctime_ms = ctimeMs(&st),
        .ctime_ns = timespecNs(if (@hasField(c.struct_stat, "st_ctim")) st.st_ctim else st.st_ctimespec),
        .uid = @intCast(st.st_uid),
        .gid = @intCast(st.st_gid),
        .owner = arena.dupe(u8, ownerName(@intCast(st.st_uid))) catch "",
        .group = arena.dupe(u8, groupName(@intCast(st.st_gid))) catch "",
        .btime_ms = btimeMsOf(&st, full),
        .nlink = @intCast(st.st_nlink),
        .blocks = if (st.st_blocks > 0) @intCast(st.st_blocks) else 0,
        .dev = @intCast(st.st_dev),
        .ino = @intCast(st.st_ino),
        .tdir = (st.st_mode & c.S_IFMT) == c.S_IFDIR,
    };
    if ((st.st_mode & c.S_IFMT) == c.S_IFLNK) {
        var tgt_buf: [4096]u8 = undefined;
        const n = c.readlink(full, &tgt_buf, tgt_buf.len - 1);
        if (n > 0) e.target = arena.dupe(u8, tgt_buf[0..@intCast(n)]) catch null;
        var fst: c.struct_stat = undefined;
        if (c.stat(full, &fst) == 0) e.tdir = (fst.st_mode & c.S_IFMT) == c.S_IFDIR;
    }
    if (count_children and e.tdir) e.children = countChildren(full);
    if (attrs.len > 0) {
        const values = arena.alloc([]const u8, attrs.len) catch return null;
        for (attrs, 0..) |attr, i| {
            values[i] = "";
            var name_z: [256:0]u8 = undefined;
            if (attr.len == 0 or attr.len >= name_z.len) continue;
            @memcpy(name_z[0..attr.len], attr);
            name_z[attr.len] = 0;
            if (getAttr(arena, full, &name_z)) |v| values[i] = v;
        }
        e.attrs = values;
    }
    if (comptime is_linux) {
        var tag_buf: [256]u8 = undefined;
        const tn = c.lgetxattr(full, TAGS_XATTR, &tag_buf, tag_buf.len);
        if (tn > 0) {
            if (std.unicode.utf8ValidateSlice(tag_buf[0..@intCast(tn)]))
                e.tags = arena.dupe(u8, tag_buf[0..@intCast(tn)]) catch "";
        }
    }
    return e;
}

/// The xattr backing file tags (comma-separated UTF-8).
pub const TAGS_XATTR = "user.sketerm.tags";

/// Read one extended attribute; null when absent, unreadable, or not
/// valid UTF-8 (the browser shows attributes as text).
pub fn getAttr(arena: std.mem.Allocator, path: [*:0]const u8, name: [*:0]const u8) ?[]const u8 {
    if (comptime !is_linux) return null;
    var buf: [MAX_ATTR_VALUE]u8 = undefined;
    const n = c.lgetxattr(path, name, &buf, buf.len);
    if (n <= 0) return null;
    const value = buf[0..@intCast(n)];
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    return arena.dupe(u8, value) catch null;
}

/// Set (or remove, with an empty value) one extended attribute.
/// Refuses anything outside the `user.` namespace: the browser must
/// not be a path to editing security or system attributes.
pub fn setAttr(path: [*:0]const u8, name: []const u8, value: []const u8) bool {
    if (comptime !is_linux) return false;
    if (!std.mem.startsWith(u8, name, "user.")) return false;
    var name_z: [256:0]u8 = undefined;
    if (name.len >= name_z.len) return false;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    if (value.len == 0) {
        _ = c.lremovexattr(path, &name_z);
        return true; // absent == cleared
    }
    if (value.len > MAX_ATTR_VALUE) return false;
    return c.lsetxattr(path, &name_z, value.ptr, value.len, 0) == 0;
}

/// Every `user.` attribute on one file, names and values.
pub fn listAttrs(arena: std.mem.Allocator, path: [*:0]const u8) []const Attr {
    if (comptime !is_linux) return &.{};
    var names: [16 * 1024]u8 = undefined;
    const n = c.llistxattr(path, &names, names.len);
    if (n <= 0) return &.{};
    var out: std.ArrayList(Attr) = .empty;
    var it = std.mem.splitScalar(u8, names[0..@intCast(n)], 0);
    while (it.next()) |name| {
        if (name.len == 0 or !std.mem.startsWith(u8, name, "user.")) continue;
        var name_z: [256:0]u8 = undefined;
        if (name.len >= name_z.len) continue;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const value = getAttr(arena, path, &name_z) orelse "(binary)";
        out.append(arena, .{
            .name = arena.dupe(u8, name) catch continue,
            .value = value,
        }) catch break;
    }
    return out.items;
}

/// Set (or clear with "") the tags xattr. Linux-only; elsewhere a
/// described error.
pub fn setTags(path: [*:0]const u8, tags: []const u8) bool {
    if (comptime !is_linux) return false;
    if (tags.len == 0) {
        _ = c.lremovexattr(path, TAGS_XATTR);
        return true; // absent == cleared
    }
    return c.lsetxattr(path, TAGS_XATTR, tags.ptr, tags.len, 0) == 0;
}

pub const Listing = struct {
    entries: []Entry,
    truncated: bool,
};

/// Read a whole directory into rich entries, sorted dirs-first then
/// case-insensitive by name — the one-round-trip listing that replaces
/// the per-entry stat chatter of network FS emulation. Non-UTF-8 names
/// are skipped (JSON cannot carry them).
pub fn listDir(arena: std.mem.Allocator, dir_path: []const u8, max: usize) error{OpenFailed}!Listing {
    return listDirAttrs(arena, dir_path, max, &.{});
}

pub fn listDirAttrs(arena: std.mem.Allocator, dir_path: []const u8, max: usize, attrs: []const []const u8) error{OpenFailed}!Listing {
    var why: []const u8 = "";
    return listDirAttrsWhy(arena, dir_path, max, attrs, &why);
}

/// As `listDirAttrs`, but names the reason the open failed.
///
/// The errno has to be captured AT the failing call: a caller that
/// reads errno after the fact may have made libc calls of its own in
/// between. Without this, a permission denial and a vanished directory
/// reached the browser as the same "cannot open directory", which is
/// the whole difference for whoever is looking at the screen.
pub fn listDirAttrsWhy(
    arena: std.mem.Allocator,
    dir_path: []const u8,
    max: usize,
    attrs: []const []const u8,
    why: *[]const u8,
) error{OpenFailed}!Listing {
    var z_buf: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z_buf, dir_path) catch {
        why.* = "NAMETOOLONG";
        return error.OpenFailed;
    };
    const dir = c.opendir(dz) orelse {
        why.* = errnoName(@as(c_int, -1));
        return error.OpenFailed;
    };
    defer _ = c.closedir(dir);

    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!std.unicode.utf8ValidateSlice(name)) continue;
        if (entries.items.len >= max) {
            truncated = true;
            break;
        }
        const e = statEntryAttrs(arena, dir_path, name, attrs, false) orelse continue;
        entries.append(arena, e) catch break;
    }
    sortEntries(entries.items);
    return .{ .entries = entries.items, .truncated = truncated };
}

pub const Names = struct {
    names: [][]u8,
    truncated: bool,
};

/// Just the entry NAMES of a directory, sorted case-insensitively —
/// the cheap first phase of an incremental listing: one readdir pass,
/// no stats. Same filters as listDir (".", "..", non-UTF-8 skipped).
pub fn readNames(
    arena: std.mem.Allocator,
    dir_path: []const u8,
    max: usize,
    why: *[]const u8,
) error{OpenFailed}!Names {
    var z_buf: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z_buf, dir_path) catch {
        why.* = "NAMETOOLONG";
        return error.OpenFailed;
    };
    const dir = c.opendir(dz) orelse {
        why.* = errnoName(@as(c_int, -1));
        return error.OpenFailed;
    };
    defer _ = c.closedir(dir);
    var names: std.ArrayList([]u8) = .empty;
    var truncated = false;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!std.unicode.utf8ValidateSlice(name)) continue;
        if (names.items.len >= max) {
            truncated = true;
            break;
        }
        const owned = arena.dupe(u8, name) catch break;
        names.append(arena, owned) catch break;
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lt);
    return .{ .names = names.items, .truncated = truncated };
}

pub fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.tdir != b.tdir) return a.tdir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lt);
}

/// Errno of the last failed libc call as a stable short name ("NOENT",
/// "ACCES") — allocation-free error strings for fs_reply.
pub fn errnoName(rc: anytype) []const u8 {
    return @tagName(std.posix.errno(rc));
}

// ── freedesktop user directories ────────────────────────────────
//
// Resolved on the host that owns the files: "New from Template" on a
// remote tab must list THAT machine's templates, and only the daemon
// running there can read its user-dirs.dirs.

/// One `XDG_*_DIR` assignment out of a user-dirs.dirs body, with
/// `$HOME` expanded. Quotes are part of the format, not of the value.
/// @return null when the key is absent or the value does not fit.
pub fn parseUserDir(content: []const u8, key: []const u8, home: []const u8, buf: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    var found: ?[]const u8 = null;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trim(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        // Last assignment wins, matching how xdg-user-dirs reads it.
        found = std.mem.trim(u8, rest[1..], " \t\"");
    }
    const value = found orelse return null;
    if (value.len == 0) return null;
    if (std.mem.startsWith(u8, value, "$HOME")) {
        const tail = value[5..];
        return std.fmt.bufPrint(buf, "{s}{s}", .{ home, tail }) catch null;
    }
    if (value[0] != '/') return null;
    return std.fmt.bufPrint(buf, "{s}", .{value}) catch null;
}

/// This host's template directory: `XDG_TEMPLATES_DIR` when
/// user-dirs.dirs sets it, else `$HOME/Templates`. The directory need
/// not exist; the caller lists it and reports an empty menu.
pub fn templatesDir(home: []const u8, config_home: []const u8, buf: []u8) []const u8 {
    var path_buf: [4096]u8 = undefined;
    const dirs = std.fmt.bufPrint(&path_buf, "{s}/user-dirs.dirs", .{config_home}) catch
        return fallbackTemplates(home, buf);
    var z: [4096]u8 = undefined;
    const zp = pathz.pathZ(&z, dirs) catch return fallbackTemplates(home, buf);
    const f = c.fopen(zp, "rb") orelse return fallbackTemplates(home, buf);
    defer _ = c.fclose(f);
    var body: [8192]u8 = undefined;
    const n = c.fread(&body, 1, body.len, f);
    return parseUserDir(body[0..n], "XDG_TEMPLATES_DIR", home, buf) orelse
        fallbackTemplates(home, buf);
}

fn fallbackTemplates(home: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/Templates", .{home}) catch "";
}

// ── inotify watcher (Linux; inert elsewhere) ────────────────────

/// Directory-content event mask for views. IN_MODIFY is deliberately
/// absent (a busy writer would flood; size updates land on
/// IN_CLOSE_WRITE / IN_ATTRIB). Self-destruction of the watched dir
/// arrives as IN_DELETE_SELF / IN_MOVE_SELF → the view is `gone`.
pub const Watcher = struct {
    fd: c_int = -1,

    /// Lazily create the inotify fd (nonblocking, cloexec). False on
    /// platforms without inotify — views then serve the initial
    /// listing with no live deltas.
    pub fn ensure(self: *Watcher) bool {
        if (comptime !is_linux) return false;
        if (self.fd >= 0) return true;
        self.fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        return self.fd >= 0;
    }

    /// Watch a directory; returns the kernel watch descriptor (shared
    /// for equal paths — the caller refcounts across views) or -1.
    pub fn add(self: *Watcher, path: [*:0]const u8) c_int {
        if (comptime !is_linux) return -1;
        if (self.fd < 0) return -1;
        const mask: u32 = c.IN_CREATE | c.IN_DELETE | c.IN_MOVED_FROM | c.IN_MOVED_TO |
            c.IN_CLOSE_WRITE | c.IN_ATTRIB | c.IN_DELETE_SELF | c.IN_MOVE_SELF;
        return c.inotify_add_watch(self.fd, path, mask);
    }

    pub fn remove(self: *Watcher, wd: c_int) void {
        if (comptime !is_linux) return;
        if (self.fd >= 0 and wd >= 0) _ = c.inotify_rm_watch(self.fd, wd);
    }

    pub fn deinit(self: *Watcher) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// One parsed inotify event. `name` points into the read buffer.
pub const InoEvent = struct {
    wd: c_int,
    mask: u32,
    name: []const u8,

    pub fn isOverflow(self: InoEvent) bool {
        if (comptime !is_linux) return false;
        return self.mask & c.IN_Q_OVERFLOW != 0;
    }
    /// The watched directory itself is gone (deleted/moved/unmounted)
    /// or the kernel dropped the watch.
    pub fn isSelfGone(self: InoEvent) bool {
        if (comptime !is_linux) return false;
        return self.mask & (c.IN_DELETE_SELF | c.IN_MOVE_SELF | c.IN_UNMOUNT | c.IN_IGNORED) != 0;
    }
    /// Entry removed from the directory.
    pub fn isRemove(self: InoEvent) bool {
        if (comptime !is_linux) return false;
        return self.mask & (c.IN_DELETE | c.IN_MOVED_FROM) != 0;
    }
};

/// Walk raw inotify_event records in a read() buffer. Alignment-safe
/// (headers decoded field-by-field, never cast).
pub const EventIter = struct {
    buf: []const u8,
    pos: usize = 0,

    const HDR = 16; // int wd, u32 mask, u32 cookie, u32 len

    pub fn next(self: *EventIter) ?InoEvent {
        if (self.pos + HDR > self.buf.len) return null;
        const b = self.buf[self.pos..];
        const wd: c_int = @bitCast(std.mem.readInt(u32, b[0..4], .little));
        const mask = std.mem.readInt(u32, b[4..8], .little);
        const nlen = std.mem.readInt(u32, b[12..16], .little);
        if (self.pos + HDR + nlen > self.buf.len) return null; // torn tail: drop
        var name: []const u8 = b[HDR .. HDR + nlen];
        // The kernel NUL-pads names to alignment; trim to the string.
        if (std.mem.indexOfScalar(u8, name, 0)) |z| name = name[0..z];
        self.pos += HDR + nlen;
        return .{ .wd = wd, .mask = mask, .name = name };
    }
};

// ── tests ───────────────────────────────────────────────────────

fn mkTmpDir(buf: *[64]u8) ?[]const u8 {
    const tmpl = "/tmp/sketerm-fsserve-XXXXXX";
    @memcpy(buf[0..tmpl.len], tmpl);
    buf[tmpl.len] = 0;
    const p = c.mkdtemp(@ptrCast(buf)) orelse return null;
    return std.mem.span(@as([*:0]u8, @ptrCast(p)));
}

fn touch(dir: []const u8, name: []const u8, content: []const u8) !void {
    var z: [4096]u8 = undefined;
    const p = try joinZ(&z, dir, name);
    const f = c.fopen(p, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (content.len > 0 and c.fwrite(content.ptr, 1, content.len, f) != content.len)
        return error.WriteFailed;
}

test "parseUserDir expands $HOME, strips quotes, and ignores comments" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const body =
        \\# generated by xdg-user-dirs
        \\XDG_DESKTOP_DIR="$HOME/Desktop"
        \\#XDG_TEMPLATES_DIR="$HOME/Ignored"
        \\XDG_TEMPLATES_DIR="$HOME/Vorlagen"
        \\XDG_MUSIC_DIR="$HOME/Music"
        \\
    ;
    try t.expectEqualStrings(
        "/home/u/Vorlagen",
        parseUserDir(body, "XDG_TEMPLATES_DIR", "/home/u", &buf).?,
    );
    // An absolute value is taken as-is; an unset key has no answer.
    try t.expectEqualStrings(
        "/srv/tpl",
        parseUserDir("XDG_TEMPLATES_DIR=/srv/tpl\n", "XDG_TEMPLATES_DIR", "/home/u", &buf).?,
    );
    try t.expect(parseUserDir(body, "XDG_VIDEOS_DIR", "/home/u", &buf) == null);
    // A disabled entry ("") must not resolve to the home directory.
    try t.expect(parseUserDir("XDG_TEMPLATES_DIR=\"\"\n", "XDG_TEMPLATES_DIR", "/home/u", &buf) == null);
}

test "templatesDir reads user-dirs.dirs and falls back to $HOME/Templates" {
    const t = std.testing;
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    // No user-dirs.dirs yet: the freedesktop default.
    try t.expectEqualStrings("/home/u/Templates", templatesDir("/home/u", dir, &buf));
    try touch(dir, "user-dirs.dirs", "XDG_TEMPLATES_DIR=\"$HOME/Modeles\"\n");
    try t.expectEqualStrings("/home/u/Modeles", templatesDir("/home/u", dir, &buf));
}

test "listDir: rich entries, dirs-first ci sort, symlink target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;

    try touch(dir, "Beta.txt", "12345");
    try touch(dir, "alpha.txt", "");
    var z: [4096]u8 = undefined;
    _ = c.mkdir(try joinZ(&z, dir, "sub"), 0o755);
    try touch(dir, "sub/inner.txt", "");
    _ = c.symlink("sub", try joinZ(&z, dir, "lnk"));

    const l = try listDir(arena, dir, MAX_ENTRIES);
    try std.testing.expectEqual(@as(usize, 4), l.entries.len);
    try std.testing.expect(!l.truncated);
    // dirs-first (sub + lnk-to-dir), then files case-insensitive.
    try std.testing.expectEqualStrings("lnk", l.entries[0].name);
    try std.testing.expectEqualStrings("sub", l.entries[1].name);
    try std.testing.expectEqualStrings("alpha.txt", l.entries[2].name);
    try std.testing.expectEqualStrings("Beta.txt", l.entries[3].name);

    try std.testing.expectEqualStrings("link", l.entries[0].kind);
    try std.testing.expect(l.entries[0].tdir);
    try std.testing.expectEqualStrings("sub", l.entries[0].target.?);
    try std.testing.expectEqualStrings("dir", l.entries[1].kind);
    try std.testing.expectEqualStrings("file", l.entries[3].kind);
    try std.testing.expectEqual(@as(u64, 5), l.entries[3].size);
    try std.testing.expect(l.entries[3].mtime_ms > 0);
    try std.testing.expect(!l.entries[3].tdir);

    // Listings never count children (that is the async follow-up);
    // a single-entry stat does, links-to-dirs included.
    try std.testing.expectEqual(@as(i64, -1), l.entries[1].children);
    try std.testing.expectEqual(@as(i64, -1), l.entries[3].children);
    const sub = statEntry(arena, dir, "sub") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), sub.children);
    const lnk = statEntry(arena, dir, "lnk") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), lnk.children);
}

test "readNames: sorted cheap phase with the same filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;
    try touch(dir, "Beta.txt", "");
    try touch(dir, "alpha.txt", "");
    var z: [4096]u8 = undefined;
    _ = c.mkdir(try joinZ(&z, dir, "sub"), 0o755);
    var why: []const u8 = "";
    const n = try readNames(arena, dir, MAX_ENTRIES, &why);
    try std.testing.expectEqual(@as(usize, 3), n.names.len);
    try std.testing.expect(!n.truncated);
    try std.testing.expectEqualStrings("alpha.txt", n.names[0]);
    try std.testing.expectEqualStrings("Beta.txt", n.names[1]);
    try std.testing.expectEqualStrings("sub", n.names[2]);
    const capped = try readNames(arena, dir, 2, &why);
    try std.testing.expect(capped.truncated);
    try std.testing.expectEqual(@as(usize, 2), capped.names.len);
}

test "listDir: entry cap sets truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;
    var i: usize = 0;
    var nb: [16]u8 = undefined;
    while (i < 10) : (i += 1) {
        const name = std.fmt.bufPrint(&nb, "f{d}", .{i}) catch unreachable;
        try touch(dir, name, "");
    }
    const l = try listDir(arena_state.allocator(), dir, 4);
    try std.testing.expectEqual(@as(usize, 4), l.entries.len);
    try std.testing.expect(l.truncated);
}

test "listDirAttrsWhy names why the open failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;

    // Absent: the reason a browser must be able to print instead of
    // rendering an empty listing.
    var z1: [4096]u8 = undefined;
    var why: []const u8 = "";
    try std.testing.expectError(
        error.OpenFailed,
        listDirAttrsWhy(arena, std.mem.span(try joinZ(&z1, dir, "nope")), MAX_ENTRIES, &.{}, &why),
    );
    try std.testing.expectEqualStrings("NOENT", why);

    // Unreadable: distinct from absent, which is the point.
    var z2: [4096]u8 = undefined;
    const locked = try joinZ(&z2, dir, "locked");
    _ = c.mkdir(locked, 0o000);
    if (c.geteuid() != 0) {
        why = "";
        try std.testing.expectError(
            error.OpenFailed,
            listDirAttrsWhy(arena, std.mem.span(locked), MAX_ENTRIES, &.{}, &why),
        );
        try std.testing.expectEqualStrings("ACCES", why);
    }
    _ = c.chmod(locked, 0o755);

    // A file where a directory was asked for.
    var z3: [4096]u8 = undefined;
    try touch(dir, "plain.txt", "x");
    why = "";
    try std.testing.expectError(
        error.OpenFailed,
        listDirAttrsWhy(arena, std.mem.span(try joinZ(&z3, dir, "plain.txt")), MAX_ENTRIES, &.{}, &why),
    );
    try std.testing.expectEqualStrings("NOTDIR", why);

    // Success leaves the reason alone.
    why = "untouched";
    _ = try listDirAttrsWhy(arena, dir, MAX_ENTRIES, &.{}, &why);
    try std.testing.expectEqualStrings("untouched", why);
}

test "watcher: create + delete surface as parsed events" {
    if (comptime !is_linux) return error.SkipZigTest;
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf) orelse return error.SkipZigTest;

    var w: Watcher = .{};
    defer w.deinit();
    try std.testing.expect(w.ensure());
    var z: [4096]u8 = undefined;
    const wd = w.add(try pathz.pathZ(&z, dir));
    try std.testing.expect(wd >= 0);

    try touch(dir, "born", "x");
    _ = c.unlink(try joinZ(&z, dir, "born"));

    var saw_create = false;
    var saw_delete = false;
    var rounds: usize = 0;
    while (rounds < 100 and !(saw_create and saw_delete)) : (rounds += 1) {
        var pfd = c.struct_pollfd{ .fd = w.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 50) <= 0) continue;
        var buf: [4096]u8 = undefined;
        const n = c.read(w.fd, &buf, buf.len);
        if (n <= 0) continue;
        var it = EventIter{ .buf = buf[0..@intCast(n)] };
        while (it.next()) |ev| {
            if (ev.wd != wd) continue;
            if (std.mem.eql(u8, ev.name, "born")) {
                if (ev.isRemove()) saw_delete = true else saw_create = true;
            }
        }
    }
    try std.testing.expect(saw_create);
    try std.testing.expect(saw_delete);
}

test "event iter: torn tail is dropped, not misparsed" {
    // Handcraft one full event + a torn header.
    var buf: [40]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 7, .little); // wd
    std.mem.writeInt(u32, buf[4..8], 0x100, .little); // mask (IN_CREATE)
    std.mem.writeInt(u32, buf[8..12], 0, .little); // cookie
    std.mem.writeInt(u32, buf[12..16], 8, .little); // len
    @memcpy(buf[16..21], "hello");
    @memset(buf[21..24], 0);
    // torn second record: header claims a name longer than the buffer
    std.mem.writeInt(u32, buf[24..28], 9, .little);
    std.mem.writeInt(u32, buf[28..32], 0x200, .little);
    std.mem.writeInt(u32, buf[32..36], 0, .little);
    std.mem.writeInt(u32, buf[36..40], 64, .little);

    var it = EventIter{ .buf = &buf };
    const first = it.next().?;
    try std.testing.expectEqual(@as(c_int, 7), first.wd);
    try std.testing.expectEqualStrings("hello", first.name);
    try std.testing.expectEqual(@as(?InoEvent, null), it.next());
}

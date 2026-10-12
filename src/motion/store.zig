//! Installed motion packs: `$XDG_DATA_HOME/sketerm/motion-packs/<name>.json`.
//! Packs never live in the repository; every write here validates the
//! pack first, so an installed file always parses.

const std = @import("std");
const c = @import("../c.zig").c;
const pack_mod = @import("pack.zig");
const xdg = @import("../util/xdg.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

pub const Error = error{ NoDataDir, InvalidName, NotInstalled, Invalid, ReadFailed, WriteFailed, OutOfMemory };

/// The packs directory, without a trailing slash.
pub fn dir(buf: []u8) ?[]const u8 {
    var base: [4096]u8 = undefined;
    const d = xdg.dataDir(&base) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/motion-packs", .{d}) catch null;
}

/// The installed file for `name`.
pub fn pathFor(buf: []u8, name: []const u8) Error![]const u8 {
    if (!pack_mod.validName(name)) return error.InvalidName;
    var d: [4096]u8 = undefined;
    const base = dir(&d) orelse return error.NoDataDir;
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ base, name }) catch error.NoDataDir;
}

/// The name a file installs under by default: its basename without `.json`.
pub fn defaultName(path: []const u8) []const u8 {
    const base = pathz.baseName(path);
    return if (std.mem.endsWith(u8, base, ".json")) base[0 .. base.len - 5] else base;
}

/// A pack's bytes, validated; `summary` describes it. Free `bytes`
/// with the allocator that was passed in.
pub const Loaded = struct {
    bytes: []u8,
    summary: pack_mod.Pack.Summary,
};

/// Read and validate a pack file at `path`; `diag` says why one is refused.
pub fn loadPath(gpa: std.mem.Allocator, path: []const u8, diag: *pack_mod.Diag) Error!Loaded {
    const bytes = readfile.cappedAlloc(gpa, path, pack_mod.MAX_BYTES) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return diag.set("pack is past the {d}-byte limit", .{pack_mod.MAX_BYTES}),
        else => return error.ReadFailed,
    };
    errdefer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = pack_mod.parse(arena.allocator(), bytes, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.Invalid,
    };
    return .{ .bytes = bytes, .summary = p.summary() };
}

/// Load the installed pack `name`.
pub fn load(gpa: std.mem.Allocator, name: []const u8, diag: *pack_mod.Diag) Error!Loaded {
    var buf: [4096]u8 = undefined;
    const path = try pathFor(&buf, name);
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return error.NotInstalled;
    if (c.access(pz, c.F_OK) != 0) return error.NotInstalled;
    return loadPath(gpa, path, diag);
}

/// Validate the pack at `src` and copy it in as `name`, replacing an
/// installed pack of that name. The file is private (0600): a pack is
/// one person's motor behaviour.
pub fn install(gpa: std.mem.Allocator, src: []const u8, name: []const u8, diag: *pack_mod.Diag) Error!pack_mod.Pack.Summary {
    var buf: [4096]u8 = undefined;
    const dest = try pathFor(&buf, name);
    const loaded = try loadPath(gpa, src, diag);
    defer gpa.free(loaded.bytes);
    try writeValidated(dest, loaded.bytes);
    return loaded.summary;
}

/// Install already-validated pack bytes as `name` (the trainer's save).
pub fn installBytes(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8, diag: *pack_mod.Diag) Error!pack_mod.Pack.Summary {
    var buf: [4096]u8 = undefined;
    const dest = try pathFor(&buf, name);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = pack_mod.parse(arena.allocator(), bytes, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.Invalid,
    };
    try writeValidated(dest, bytes);
    return p.summary();
}

fn writeValidated(dest: []const u8, bytes: []const u8) Error!void {
    var d: [4096]u8 = undefined;
    const base = dir(&d) orelse return error.NoDataDir;
    pathz.makeDirs(base, 0o700) catch return error.WriteFailed;
    atomicwrite.writeFileExact(dest, bytes, 0o600) catch return error.WriteFailed;
}

/// Remove the installed pack `name`.
pub fn remove(name: []const u8) Error!void {
    var buf: [4096]u8 = undefined;
    const path = try pathFor(&buf, name);
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return error.NotInstalled;
    if (c.unlink(pz) != 0) return error.NotInstalled;
}

pub const Entry = struct {
    name: []u8,
    /// Null when the file no longer validates; `why` says what is wrong.
    summary: ?pack_mod.Pack.Summary,
    why: []u8,
};

/// Every `*.json` in the packs directory, sorted by name. Free with `freeList`.
pub fn list(gpa: std.mem.Allocator) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer freeList(gpa, out.items);
    var d: [4096]u8 = undefined;
    const base = dir(&d) orelse return error.NoDataDir;
    var z: [4096]u8 = undefined;
    const bz = pathz.pathZ(&z, base) catch return error.NoDataDir;
    const handle = c.opendir(bz) orelse return out.toOwnedSlice(gpa);
    defer _ = c.closedir(handle);
    while (c.readdir(handle)) |ent| {
        const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, fname, ".json")) continue;
        const name = fname[0 .. fname.len - 5];
        if (!pack_mod.validName(name)) continue;
        var diag: pack_mod.Diag = .{};
        var pbuf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ base, fname }) catch continue;
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        if (loadPath(gpa, path, &diag)) |loaded| {
            gpa.free(loaded.bytes);
            try out.append(gpa, .{ .name = owned_name, .summary = loaded.summary, .why = try gpa.dupe(u8, "") });
        } else |err| {
            const why = if (diag.len > 0) try gpa.dupe(u8, diag.msg()) else try gpa.dupe(u8, @errorName(err));
            try out.append(gpa, .{ .name = owned_name, .summary = null, .why = why });
        }
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.why);
    }
    gpa.free(entries);
}

test "install, list, load and remove a generated pack under XDG_DATA_HOME" {
    const t = std.testing;
    const env = @import("../util/env.zig");
    const td = pathz.TempDir.make("motion") orelse return error.SkipZigTest;
    defer td.remove();
    const old = env.get("XDG_DATA_HOME");
    var old_buf: [4096]u8 = undefined;
    const saved: ?[:0]const u8 = if (old) |o| (std.fmt.bufPrintZ(&old_buf, "{s}", .{o}) catch null) else null;
    defer if (saved) |s| {
        _ = c.setenv("XDG_DATA_HOME", s.ptr, 1);
    } else {
        _ = c.unsetenv("XDG_DATA_HOME");
    };
    _ = c.setenv("XDG_DATA_HOME", td.pathZ(), 1);

    const bytes = try @import("synth.zig").generate(t.allocator, .{ .seed = 9 });
    defer t.allocator.free(bytes);
    var src_buf: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/my-mouse.json", .{td.path()});
    try atomicwrite.writeFileExact(src, bytes, 0o600);

    var diag: pack_mod.Diag = .{};
    const s = try install(t.allocator, src, defaultName(src), &diag);
    try t.expectEqual(pack_mod.Device.mouse, s.device);
    try t.expectError(error.InvalidName, install(t.allocator, src, "../evil", &diag));

    const entries = try list(t.allocator);
    defer freeList(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expectEqualStrings("my-mouse", entries[0].name);
    try t.expect(entries[0].summary != null);

    const loaded = try load(t.allocator, "my-mouse", &diag);
    defer t.allocator.free(loaded.bytes);
    try t.expectEqual(s.reaches, loaded.summary.reaches);

    // A broken file is refused at install and keeps nothing.
    try atomicwrite.writeFileExact(src, "{\"format\":\"sketerm-motion\",\"version\":7}", 0o600);
    try t.expectError(error.Invalid, install(t.allocator, src, "broken", &diag));
    try t.expectError(error.NotInstalled, load(t.allocator, "broken", &diag));

    try remove("my-mouse");
    try t.expectError(error.NotInstalled, load(t.allocator, "my-mouse", &diag));
    try t.expectError(error.NotInstalled, remove("my-mouse"));
}

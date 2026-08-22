//! Persistent MCP assets: named screenshot templates (PNG) and named
//! input macros (JSON step lists) under $XDG_STATE_HOME/sketerm.
//! Shared across MCP instances deliberately — a macro recorded in one
//! session must replay in the next (that is the whole point).
//!
//! libc file IO only (Zig 0.16 has no std.fs.cwd); bounded reads —
//! a template above MAX_BYTES is rejected rather than truncated.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");

pub const Error = error{ BadName, NotFound, TooBig, IoFailed, OutOfMemory };

pub const Kind = enum {
    template,
    macro,

    fn dir(self: Kind) []const u8 {
        return switch (self) {
            .template => "templates",
            .macro => "macros",
        };
    }

    fn ext(self: Kind) []const u8 {
        return switch (self) {
            .template => ".png",
            .macro => ".json",
        };
    }
};

/// 8 MB: a full-window PNG template fits many times over; a macro is
/// text. Anything bigger is a mistake, not an asset.
pub const MAX_BYTES: usize = 8 << 20;

/// An empty variable reads as unset, like a missing one.
const getenv = @import("../util/env.zig").nonEmpty;

/// Asset names are file names: short, no separators, no dotfiles.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.') return false;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn assetPath(allocator: std.mem.Allocator, kind: Kind, name: []const u8) Error![]u8 {
    if (!validName(name)) return Error.BadName;
    if (getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/{s}/{s}{s}", .{ xs, kind.dir(), name, kind.ext() }) catch Error.OutOfMemory;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/{s}/{s}{s}", .{ home, kind.dir(), name, kind.ext() }) catch Error.OutOfMemory;
    }
    return Error.IoFailed;
}

fn dirPath(allocator: std.mem.Allocator, kind: Kind) Error![]u8 {
    if (getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/{s}", .{ xs, kind.dir() }) catch Error.OutOfMemory;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/{s}", .{ home, kind.dir() }) catch Error.OutOfMemory;
    }
    return Error.IoFailed;
}

pub fn save(allocator: std.mem.Allocator, kind: Kind, name: []const u8, bytes: []const u8) Error!void {
    if (bytes.len > MAX_BYTES) return Error.TooBig;
    const path = try assetPath(allocator, kind, name);
    defer allocator.free(path);
    try saveToPath(path, bytes);
}

fn saveToPath(path: []const u8, bytes: []const u8) Error!void {
    pathz.makeParentDirs(path) catch return Error.IoFailed;
    atomicwrite.writeFileExact(path, bytes, 0o600) catch return Error.IoFailed;
}

/// Caller frees the returned bytes.
pub fn load(allocator: std.mem.Allocator, kind: Kind, name: []const u8) Error![]u8 {
    const path = try assetPath(allocator, kind, name);
    defer allocator.free(path);
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return Error.IoFailed;
    const f = c.fopen(z, "rb") orelse return Error.NotFound;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const len: usize = @intCast(@max(0, c.ftell(f)));
    _ = c.fseek(f, 0, c.SEEK_SET);
    if (len > MAX_BYTES) return Error.TooBig;
    const buf = allocator.alloc(u8, len) catch return Error.OutOfMemory;
    errdefer allocator.free(buf);
    if (c.fread(buf.ptr, 1, len, f) != len) return Error.IoFailed;
    return buf;
}

pub fn delete(allocator: std.mem.Allocator, kind: Kind, name: []const u8) Error!void {
    const path = try assetPath(allocator, kind, name);
    defer allocator.free(path);
    atomicwrite.deleteFile(path) catch |err| return switch (err) {
        error.NotFound => Error.NotFound,
        else => Error.IoFailed,
    };
}

/// Names (extension stripped) of every stored asset of `kind`,
/// sorted. Caller frees each name and the slice.
pub fn list(allocator: std.mem.Allocator, kind: Kind) Error![][]u8 {
    const path = try dirPath(allocator, kind);
    defer allocator.free(path);
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return Error.IoFailed;
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    const d = c.opendir(z) orelse return names.toOwnedSlice(allocator) catch Error.OutOfMemory;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, fname, kind.ext())) continue;
        const stem = fname[0 .. fname.len - kind.ext().len];
        if (!validName(stem)) continue;
        const copy = allocator.dupe(u8, stem) catch return Error.OutOfMemory;
        names.append(allocator, copy) catch {
            allocator.free(copy);
            return Error.OutOfMemory;
        };
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

// ─── tests ──────────────────────────────────────────────────────

test "asset names are validated" {
    try std.testing.expect(validName("conversation-frame"));
    try std.testing.expect(validName("a.b_C-9"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName("x" ** 65));
}

test "save/load/list/delete round-trip in an isolated state dir" {
    const a = std.testing.allocator;
    var dirbuf = "/tmp/sketerm-assets-test-XXXXXX".*;
    const dir_z = c.mkdtemp(&dirbuf) orelse return error.SkipZigTest;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(dir_z)));
    var zbuf: [4096]u8 = undefined;
    var envbuf: [160]u8 = undefined;
    const env = try std.fmt.bufPrintZ(&envbuf, "{s}", .{dir});
    _ = c.setenv("XDG_STATE_HOME", env, 1);
    defer {
        _ = c.unsetenv("XDG_STATE_HOME");
        if (std.fmt.bufPrintZ(&zbuf, "{s}/sketerm/macros", .{dir})) |macros| {
            _ = c.rmdir(macros.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/sketerm", .{dir})) |root| {
            _ = c.rmdir(root.ptr);
        } else |_| {}
        _ = c.rmdir(dir_z);
    }

    try save(a, .macro, "walk-to-riker", "{\"actions\":[{\"wait\":100}]}");
    const bytes = try load(a, .macro, "walk-to-riker");
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{\"actions\":[{\"wait\":100}]}", bytes);

    const path = try assetPath(a, .macro, "walk-to-riker");
    defer a.free(path);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(try pathz.pathZ(&zbuf, path), &st) == 0);
    try std.testing.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    const too_big = try a.alloc(u8, MAX_BYTES + 1);
    defer a.free(too_big);
    try std.testing.expectError(Error.TooBig, save(a, .macro, "walk-to-riker", too_big));
    const retained = try load(a, .macro, "walk-to-riker");
    defer a.free(retained);
    try std.testing.expectEqualStrings("{\"actions\":[{\"wait\":100}]}", retained);

    const names = try list(a, .macro);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("walk-to-riker", names[0]);

    try delete(a, .macro, "walk-to-riker");
    try std.testing.expectError(Error.NotFound, load(a, .macro, "walk-to-riker"));
    try std.testing.expectError(Error.BadName, save(a, .macro, "../evil", "x"));
}

test "concurrent asset saves install one complete value and clean stages" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-assets-race-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/macro.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    const Ctx = struct {
        path: []const u8,
        bytes: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            saveToPath(self.path, self.bytes) catch {
                self.failed = true;
            };
        }
    };
    var one = Ctx{ .path = path, .bytes = "{\"writer\":1}" };
    var two = Ctx{ .path = path, .bytes = "{\"writer\":2}" };
    const first = try std.Thread.spawn(.{}, Ctx.run, .{&one});
    const second = try std.Thread.spawn(.{}, Ctx.run, .{&two});
    first.join();
    second.join();
    try t.expect(!one.failed and !two.failed);

    const f = c.fopen(path_z.ptr, "rb") orelse return error.TestUnexpectedResult;
    defer _ = c.fclose(f);
    var bytes: [32]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, f);
    try t.expect(std.mem.eql(u8, bytes[0..n], one.bytes) or std.mem.eql(u8, bytes[0..n], two.bytes));

    const dp = c.opendir(dir) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        try t.expect(std.mem.indexOf(u8, name, ".sketerm-tmp-") == null);
    }
}

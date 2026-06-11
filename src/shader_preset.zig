//! Shader presets — a named "shader file + parameter values" combo,
//! stored one file per preset under
//! `$XDG_CONFIG_HOME/sketerm/shader-presets/<name>.conf`:
//!
//!   shader = /path/to/crt.glsl
//!   animate = true
//!   param.curvature = 0.05
//!   param.phosphor = #ffb233
//!
//! Pure parse/serialize below is unit-tested; file IO goes through
//! libc like config.zig (std.fs.cwd is gone in Zig 0.16).

const std = @import("std");
const c = @import("c.zig").c;
const ParamKV = @import("render/shader_pass.zig").ParamKV;
const pathz_util = @import("util/pathz.zig");

pub const Preset = struct {
    name: []const u8 = "",
    shader_path: []const u8 = "",
    animate: bool = true,
    params: []const ParamKV = &.{},
};

pub const MAX_NAME = 64;

/// Directory holding the preset files (not created here).
pub fn presetsDir(allocator: std.mem.Allocator) ![]u8 {
    const profile = @import("util/profile.zig");
    if (profile.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/shader-presets", .{xdg});
    }
    const home = profile.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/shader-presets", .{home});
}

/// A name is a filename stem: printable ASCII, no '/', no leading dot.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (name[0] == '.') return false;
    for (name) |ch| {
        if (ch == '/' or ch < 0x20 or ch > 0x7e) return false;
    }
    return true;
}

pub fn serialize(allocator: std.mem.Allocator, preset: Preset) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("shader = {s}\n", .{preset.shader_path});
    try w.print("animate = {s}\n", .{if (preset.animate) "true" else "false"});
    for (preset.params) |p| {
        if (p.color) |col| {
            try w.print("param.{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{
                p.name,
                colByte(col[0]),
                colByte(col[1]),
                colByte(col[2]),
            });
        } else {
            try w.print("param.{s} = {d}\n", .{ p.name, p.value });
        }
    }
    return out.toOwnedSlice();
}

fn colByte(v: f32) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

/// Parse preset text. All slices in the result are duped into
/// `allocator` (use an arena). `name` is NOT set (it's the filename).
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Preset {
    var preset: Preset = .{};
    var params: std.ArrayList(ParamKV) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "shader")) {
            preset.shader_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "animate")) {
            preset.animate = std.mem.eql(u8, value, "true");
        } else if (std.mem.startsWith(u8, key, "param.")) {
            const pname = key["param.".len..];
            if (pname.len == 0) continue;
            var kv: ParamKV = .{ .name = try allocator.dupe(u8, pname) };
            if (value.len == 7 and value[0] == '#') {
                const r = std.fmt.parseInt(u8, value[1..3], 16) catch continue;
                const g = std.fmt.parseInt(u8, value[3..5], 16) catch continue;
                const b = std.fmt.parseInt(u8, value[5..7], 16) catch continue;
                kv.color = .{
                    @as(f32, @floatFromInt(r)) / 255.0,
                    @as(f32, @floatFromInt(g)) / 255.0,
                    @as(f32, @floatFromInt(b)) / 255.0,
                };
            } else {
                kv.value = std.fmt.parseFloat(f32, value) catch continue;
            }
            try params.append(allocator, kv);
        }
    }
    preset.params = try params.toOwnedSlice(allocator);
    return preset;
}

pub fn save(allocator: std.mem.Allocator, preset: Preset) !void {
    if (!validName(preset.name)) return error.BadName;
    const dir = try presetsDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ dir, preset.name });
    defer allocator.free(path);
    try pathz_util.makeParentDirs(path);
    const text = try serialize(allocator, preset);
    defer allocator.free(text);

    var path_z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz_util.pathZ(&path_z, path), "wb") orelse return error.WriteFailed;
    const written = c.fwrite(text.ptr, 1, text.len, fp);
    const close_ok = c.fclose(fp) == 0;
    if (written != text.len or !close_ok) return error.WriteFailed;
}

/// Load a preset by name; everything duped into `allocator` (use an
/// arena), including `name`.
pub fn load(allocator: std.mem.Allocator, name: []const u8) !Preset {
    if (!validName(name)) return error.BadName;
    const dir = try presetsDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ dir, name });
    defer allocator.free(path);

    var path_z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz_util.pathZ(&path_z, path), "rb") orelse return error.NotFound;
    defer _ = c.fclose(fp);
    const buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buf);
    const n = c.fread(buf.ptr, 1, buf.len, fp);
    var preset = try parse(allocator, buf[0..n]);
    preset.name = try allocator.dupe(u8, name);
    return preset;
}

pub fn delete(allocator: std.mem.Allocator, name: []const u8) !void {
    if (!validName(name)) return error.BadName;
    const dir = try presetsDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ dir, name });
    defer allocator.free(path);
    var path_z: [4096]u8 = undefined;
    if (c.unlink(try pathz_util.pathZ(&path_z, path)) != 0) return error.DeleteFailed;
}

/// Sorted preset names (filename stems of *.conf), duped into
/// `allocator` (use an arena). Missing dir = empty list.
pub fn list(allocator: std.mem.Allocator) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    const dir_path = try presetsDir(allocator);
    defer allocator.free(dir_path);
    var path_z: [4096]u8 = undefined;
    const dirp = c.opendir(try pathz_util.pathZ(&path_z, dir_path)) orelse
        return names.toOwnedSlice(allocator);
    defer _ = c.closedir(dirp);
    while (c.readdir(dirp)) |ent| {
        const dname: [*:0]const u8 = @ptrCast(&ent.*.d_name);
        const name = std.mem.span(dname);
        if (!std.mem.endsWith(u8, name, ".conf")) continue;
        const stem = name[0 .. name.len - ".conf".len];
        if (!validName(stem)) continue;
        try names.append(allocator, try allocator.dupe(u8, stem));
    }
    const slice = try names.toOwnedSlice(allocator);
    std.mem.sort([]u8, slice, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return slice;
}

test "preset serialize/parse round-trip" {
    const a = std.testing.allocator;
    const params = [_]ParamKV{
        .{ .name = "curvature", .value = 0.05 },
        .{ .name = "phosphor", .color = .{ 1.0, 0.7, 0.2 } },
    };
    const text = try serialize(a, .{
        .name = "amber",
        .shader_path = "/tmp/crt.glsl",
        .animate = true,
        .params = &params,
    });
    defer a.free(text);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(), text);
    try std.testing.expectEqualStrings("/tmp/crt.glsl", p.shader_path);
    try std.testing.expect(p.animate);
    try std.testing.expectEqual(@as(usize, 2), p.params.len);
    try std.testing.expectEqualStrings("curvature", p.params[0].name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), p.params[0].value, 0.0001);
    try std.testing.expectEqualStrings("phosphor", p.params[1].name);
    const col = p.params[1].color.?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), col[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), col[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), col[2], 0.01);
}

test "preset parse ignores junk and comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(),
        \\# comment
        \\shader = /a/b.glsl
        \\animate = false
        \\nonsense line
        \\param. = 1
        \\param.x = notafloat
        \\param.ok = 2.5
    );
    try std.testing.expectEqualStrings("/a/b.glsl", p.shader_path);
    try std.testing.expect(!p.animate);
    try std.testing.expectEqual(@as(usize, 1), p.params.len);
    try std.testing.expectEqualStrings("ok", p.params[0].name);
}

test "validName rejects path escapes" {
    try std.testing.expect(validName("Amber CRT"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("x" ** 65));
}

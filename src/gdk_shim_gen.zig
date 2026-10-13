//! Build-time generator for the Aro shim of `gdk/version/gdkversionmacros.h`.
//!
//! Aro (Zig 0.16 translate-c) honours `#pragma once` only AT the directive,
//! but GTK's header carries its `#error "Only <gdk/gdk.h> can be included
//! directly."` guard on the lines BEFORE it, and `gdk.h` `#undef`s
//! `__GDK_H_INSIDE__` on its way out, so the next re-include from a GTK
//! header fires the error. The shim is the HOST's own header with exactly
//! that guard block removed, wrapped in an include guard of ours because
//! Aro reprocesses the text ahead of `#pragma once`. It used to be a
//! vendored copy, which drifted from every host GTK by construction.
//!
//! Invoked by `build.zig` as
//! `gdk_shim_gen <pkg-config --cflags-only-I gtk4 output> <out dir> <dep file>`.
//! The first `-I` directory holding the header wins (compiler search order);
//! the header is reported in the dep file so a GTK upgrade regenerates.

const std = @import("std");

pub const header_sub_path = "gdk/version/gdkversionmacros.h";

const guard_error_line = "#error \"Only <gdk/gdk.h> can be included directly.\"";
const wrap_macro = "__SKETERM_SHIM_GDK_VERSION_MACROS_H__";

pub const prefix =
    "/* sketerm shim, GENERATED at build time by src/gdk_shim_gen.zig from the\n" ++
    " * host's gdk/version/gdkversionmacros.h with only the\n" ++
    " * \"Only <gdk/gdk.h> can be included directly.\" guard block removed.\n" ++
    " * Aro does not honour `#pragma once` before the guard's `#error`.\n" ++
    " * Do not edit; drop the generator once Aro skips before any directive. */\n" ++
    "\n" ++
    "#ifndef " ++ wrap_macro ++ "\n" ++
    "#define " ++ wrap_macro ++ "\n" ++
    "\n";

pub const suffix = "\n#endif /* " ++ wrap_macro ++ " */\n";

pub const TransformError = error{ MissingGuard, MalformedGuard, DuplicateGuard, OutOfMemory };

const Span = struct { start: usize, end: usize };

/// Locate the `#if` / `#error "Only <gdk/gdk.h>..."` / `#endif` block, line endings included.
fn findGuard(header: []const u8) TransformError!Span {
    const err_at = std.mem.indexOf(u8, header, guard_error_line) orelse return error.MissingGuard;
    if (std.mem.indexOfPos(u8, header, err_at + guard_error_line.len, guard_error_line) != null)
        return error.DuplicateGuard;

    const err_start = lineStart(header, err_at);
    if (err_start != err_at) return error.MalformedGuard;
    if (err_start == 0) return error.MalformedGuard;
    const if_start = lineStart(header, err_start - 1);
    if (!std.mem.startsWith(u8, header[if_start..], "#if")) return error.MalformedGuard;

    const err_end = lineEnd(header, err_start) orelse return error.MalformedGuard;
    const endif_end = lineEnd(header, err_end) orelse header.len;
    const endif_line = std.mem.trimEnd(u8, header[err_end..endif_end], "\r\n");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, endif_line, " \t"), "#endif")) return error.MalformedGuard;
    return .{ .start = if_start, .end = endif_end };
}

fn lineStart(s: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, s[0..pos], '\n')) |nl| nl + 1 else 0;
}

/// @return the offset just past `pos`'s line terminator, or null on an unterminated last line.
fn lineEnd(s: []const u8, pos: usize) ?usize {
    const nl = std.mem.indexOfScalarPos(u8, s, pos, '\n') orelse return null;
    return nl + 1;
}

/// Build the shim: `prefix` ++ header minus the guard block ++ `suffix`; caller owns the result.
pub fn transform(gpa: std.mem.Allocator, header: []const u8) TransformError![]u8 {
    const guard = try findGuard(header);
    return std.mem.concat(gpa, u8, &.{ prefix, header[0..guard.start], header[guard.end..], suffix });
}

/// Split pkg-config `-I` output into directories, honouring its backslash escapes.
fn includeDirs(gpa: std.mem.Allocator, cflags: []const u8) ![][]u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    var tok: std.ArrayList(u8) = .empty;
    defer tok.deinit(gpa);
    var i: usize = 0;
    while (i <= cflags.len) : (i += 1) {
        const ch: u8 = if (i < cflags.len) cflags[i] else ' ';
        if (ch == '\\' and i + 1 < cflags.len) {
            i += 1;
            try tok.append(gpa, cflags[i]);
        } else if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (std.mem.startsWith(u8, tok.items, "-I") and tok.items.len > 2) {
                try dirs.append(gpa, try gpa.dupe(u8, tok.items[2..]));
            }
            tok.clearRetainingCapacity();
        } else {
            try tok.append(gpa, ch);
        }
    }
    return dirs.toOwnedSlice(gpa);
}

/// Write one dep-file prerequisite; Zig's dep tokenizer resolves only `\ ` inside a prerequisite.
fn writeDepPath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |ch| {
        if (ch == ' ') try w.writeByte('\\');
        try w.writeByte(ch);
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const cflags_path = args.next() orelse return usage();
    const out_dir_path = args.next() orelse return usage();
    const dep_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const cwd = std.Io.Dir.cwd();
    const cflags = try cwd.readFileAlloc(io, cflags_path, gpa, .limited(1 << 20));
    defer gpa.free(cflags);
    const dirs = try includeDirs(gpa, cflags);
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }

    var found: ?[]u8 = null;
    defer if (found) |p| gpa.free(p);
    for (dirs) |dir| {
        const candidate = try std.fs.path.join(gpa, &.{ dir, header_sub_path });
        if (cwd.access(io, candidate, .{})) |_| {
            found = candidate;
            break;
        } else |_| gpa.free(candidate);
    }
    const header_path = found orelse {
        std.debug.print(
            "error: {s} not found in any include directory of `pkg-config --cflags-only-I gtk4` ({s}); the GUI's C bindings cannot be generated without it\n",
            .{ header_sub_path, std.mem.trim(u8, cflags, " \r\n\t") },
        );
        return 1;
    };

    const header = try cwd.readFileAlloc(io, header_path, gpa, .limited(1 << 20));
    defer gpa.free(header);
    const shim = transform(gpa, header) catch |err| {
        std.debug.print(
            "error: {s}: {s}; expected exactly one `#if ...` / `{s}` / `#endif` block, update src/gdk_shim_gen.zig for this GTK\n",
            .{ header_path, @errorName(err), guard_error_line },
        );
        return 1;
    };
    defer gpa.free(shim);

    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);
    try out_dir.createDirPath(io, std.fs.path.dirname(header_sub_path).?);
    try out_dir.writeFile(io, .{ .sub_path = header_sub_path, .data = shim });

    var dep: std.Io.Writer.Allocating = .init(gpa);
    defer dep.deinit();
    try dep.writer.writeAll("gdkversionmacros.h: ");
    try writeDepPath(&dep.writer, header_path);
    try dep.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = dep_path, .data = dep.written() });
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: gdk_shim_gen <cflags file> <out dir> <dep file>\n", .{});
    return 2;
}

const sample =
    "/* license */\n" ++
    "\n" ++
    "#if !defined (__GDK_H_INSIDE__) && !defined (GTK_COMPILATION)\n" ++
    guard_error_line ++ "\n" ++
    "#endif\n" ++
    "\n" ++
    "#pragma once\n" ++
    "#define GDK_MINOR_VERSION (22)\n";

test "transform removes exactly the guard block and keeps everything else byte-identical" {
    const gpa = std.testing.allocator;
    const out = try transform(gpa, sample);
    defer gpa.free(out);
    const expected = prefix ++
        "/* license */\n\n" ++
        "\n#pragma once\n#define GDK_MINOR_VERSION (22)\n" ++
        suffix;
    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expect(std.mem.indexOf(u8, out, guard_error_line) == null);
}

test "transform keeps CRLF line endings outside the guard" {
    const gpa = std.testing.allocator;
    const crlf = "a\r\n#if X\r\n" ++ guard_error_line ++ "\r\n#endif\r\nb\r\n";
    const out = try transform(gpa, crlf);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(prefix ++ "a\r\nb\r\n" ++ suffix, out);
}

test "transform rejects a header without the guard" {
    try std.testing.expectError(error.MissingGuard, transform(std.testing.allocator, "#pragma once\n#define X 1\n"));
}

test "transform rejects a guard not wrapped in #if/#endif" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MalformedGuard, transform(gpa, guard_error_line ++ "\n#endif\n"));
    try std.testing.expectError(error.MalformedGuard, transform(gpa, "#if X\n" ++ guard_error_line ++ "\n#define Y\n"));
    try std.testing.expectError(error.MalformedGuard, transform(gpa, "#if X\n  " ++ guard_error_line ++ "\n#endif\n"));
}

test "transform rejects a duplicated guard" {
    const block = "#if X\n" ++ guard_error_line ++ "\n#endif\n";
    try std.testing.expectError(error.DuplicateGuard, transform(std.testing.allocator, block ++ block));
}

test "includeDirs keeps only -I paths and honours escaped spaces" {
    const gpa = std.testing.allocator;
    const dirs = try includeDirs(gpa, "-I/usr/include/gtk-4.0 -pthread -I/opt/my\\ gtk/include\n");
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
    try std.testing.expectEqualStrings("/usr/include/gtk-4.0", dirs[0]);
    try std.testing.expectEqualStrings("/opt/my gtk/include", dirs[1]);
}

test "writeDepPath escapes spaces only" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeDepPath(&buf.writer, "/a b/$c#d");
    try std.testing.expectEqualStrings("/a\\ b/$c#d", buf.written());
}

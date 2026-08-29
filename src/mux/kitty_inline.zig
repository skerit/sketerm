//! Daemon-side kitty-graphics file fetch.
//!
//! Over a mux transport the file-based kitty transmission media
//! (`t=f` path, `t=t` tempfile, `t=s` POSIX shm) reference files on
//! the REMOTE host -- the attached GUI could never read them. The
//! daemon runs on that host, so it reads the data itself and
//! rewrites the APC to an inline `t=d` transmission before
//! broadcasting. Apps that "don't work over SSH" just work.
//!
//! Tempfile/shm deletion is honored daemon-side, exactly as a
//! terminal would, and it is honored on a REFUSAL too: a `t=t` path
//! carrying the spec's `tty-graphics-protocol` marker and every `t=s`
//! object are unlinked once the path is known, whether or not the
//! bytes were inlined. Nobody else will: the client never receives a
//! refused APC, so the file it names would otherwise stay behind.
//!
//! An APC this module cannot inline is DROPPED by the caller, never
//! forwarded. The daemon cannot know whether an attached client shares
//! its filesystem, and `grid/kitty_images.zig` resolves the path on
//! whatever host applies the event -- unlinking it there for `t=t`. A
//! forwarded file-medium APC is therefore a file-deletion primitive
//! aimed at every viewer, which is why every refusal below is a
//! refusal rather than a fallback, and why it says WHICH refusal it
//! is: the caller logs the first drop of a session at warn level so a
//! vanished image is explainable.

const std = @import("std");
const c = @import("../c.zig").c;
const kitty = @import("../parser/kitty_image.zig");
const pathz = @import("../util/pathz.zig");
const pathZ = pathz.pathZ;
const readfile = @import("../util/readfile.zig");
const wire = @import("wire.zig");

/// Raw-bytes cap. The whole rewritten APC rides one wire EVENTS frame
/// (`wire.MAX_FRAME`, 16 MiB) together with the rest of the drain
/// batch. A drain reads at most 8 x 32 KiB of PTY bytes, and no
/// serialized event is more than a small multiple of the bytes that
/// produced it, so the rest of the batch stays under 2 MiB even in
/// the pathological one-event-per-byte case; base64 expands 4/3 plus
/// the APC head, so 10 MiB raw is about 13.4 MiB encoded and the sum
/// still clears the frame. A larger file cannot be inlined and its
/// APC is dropped: the image is lost rather than forwarded as a path
/// the viewer would resolve against its own disk. Two such images in
/// ONE drain overflow the frame and take the serialization-failed
/// snapshot resync path, exactly as before.
pub const MAX_RAW_BYTES: usize = 10 * 1024 * 1024;

comptime {
    const worst_rest_of_batch = 2 * 1024 * 1024;
    const apc_head = 4096;
    if ((MAX_RAW_BYTES * 4 + 2) / 3 + apc_head + worst_rest_of_batch > wire.MAX_FRAME)
        @compileError("MAX_RAW_BYTES no longer fits one EVENTS frame with the rest of a drain");
}

/// Why an APC was not inlined; `describe` is the log wording.
pub const Refusal = enum {
    not_file_medium,
    bad_path,
    chunked,
    too_large,
    unreadable,
    out_of_memory,

    pub fn describe(self: Refusal) []const u8 {
        return switch (self) {
            .not_file_medium => "not a file-medium transmission",
            .bad_path => "the payload is not a decodable path",
            .chunked => "a chunked (m=1) file transmission is malformed",
            .too_large => "the file is over the inline cap",
            .unreadable => "the file cannot be read on the daemon host",
            .out_of_memory => "out of memory while inlining",
        };
    }
};

/// A refusal with what the caller needs to explain it: the medium,
/// the file size when it was learned, and a bounded copy of the path.
pub const Refused = struct {
    why: Refusal,
    medium: u8 = 'd',
    size: u64 = 0,
    path_buf: [PATH_NOTE]u8 = undefined,
    path_len: u8 = 0,

    const PATH_NOTE = 200;

    pub fn path(self: *const Refused) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn of(why: Refusal, medium: u8, size: u64, p: []const u8) Refused {
        var r: Refused = .{ .why = why, .medium = medium, .size = size };
        const n = @min(p.len, PATH_NOTE);
        @memcpy(r.path_buf[0..n], p[0..n]);
        r.path_len = @intCast(n);
        return r;
    }
};

pub const Result = union(enum) {
    /// The replacement APC (`t=d`, payload inlined); caller owns it.
    inlined: []u8,
    refused: Refused,
};

/// If `apc_bytes` is a kitty file/tempfile/shm transmission, fetch
/// the data locally and return a replacement APC with `t=d` and the
/// base64 payload inlined.
///
/// A refusal means the APC could not be inlined, which the caller
/// answers by DROPPING the event -- see the module docblock. Callers
/// gate on `kitty_image.isFileMedium` first, so in practice a refusal
/// reaches them only for a file medium that failed. Cleanup of a
/// `t=t`/`t=s` source happens on refusal as well as success.
pub fn rewrite(allocator: std.mem.Allocator, apc_bytes: []const u8) Result {
    return rewriteWithCap(allocator, apc_bytes, MAX_RAW_BYTES);
}

/// `rewrite` with the raw-bytes cap as a parameter, so a test can
/// exercise the over-cap refusal without writing MAX_RAW_BYTES to disk.
pub fn rewriteWithCap(allocator: std.mem.Allocator, apc_bytes: []const u8, cap: usize) Result {
    const cmd = kitty.parse(apc_bytes) catch return .{ .refused = .{ .why = .not_file_medium } };
    if (!kitty.isFileMedium(cmd.medium)) return .{ .refused = .{ .why = .not_file_medium } };
    if (cmd.payload.len == 0) return .{ .refused = .{ .why = .bad_path, .medium = cmd.medium } };
    // File transmissions carry the whole path in one APC. A chunked
    // first chunk holds a PREFIX of the path, which must not be
    // resolved (or unlinked) as if it were the whole thing.
    if (cmd.more != 0) return .{ .refused = .{ .why = .chunked, .medium = cmd.medium } };

    // Payload is the base64-encoded path.
    var path_buf: [4096]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const plen = decoder.calcSizeForSlice(cmd.payload) catch
        return .{ .refused = .{ .why = .bad_path, .medium = cmd.medium } };
    if (plen >= path_buf.len) return .{ .refused = .{ .why = .bad_path, .medium = cmd.medium } };
    decoder.decode(path_buf[0..plen], cmd.payload) catch
        return .{ .refused = .{ .why = .bad_path, .medium = cmd.medium } };
    const path_raw = std.mem.trimEnd(u8, path_buf[0..plen], "\x00 \r\n\t");

    var shm_buf: [4096]u8 = undefined;
    const path = if (cmd.medium == 's')
        kitty.shmPath(&shm_buf, path_raw) orelse
            return .{ .refused = .{ .why = .bad_path, .medium = cmd.medium } }
    else
        path_raw;

    // The spec makes the terminal responsible for cleanup of tempfiles
    // and shm objects; the daemon is the terminal here. Deferred so
    // every exit below this point, refusal included, honors it -- and
    // it runs AFTER the read, which is the only ordering that works.
    const cleanup = cmd.medium == 's' or (cmd.medium == 't' and kitty.tempfileDeletable(path));
    defer if (cleanup) pathz.unlinkPath(path);

    const size = fileSize(path) orelse
        return .{ .refused = Refused.of(.unreadable, cmd.medium, 0, path) };
    if (size > cap) return .{ .refused = Refused.of(.too_large, cmd.medium, size, path) };
    const data = (readfile.sized(allocator, path, cap) catch
        return .{ .refused = Refused.of(.out_of_memory, cmd.medium, size, path) }) orelse
        return .{ .refused = Refused.of(.unreadable, cmd.medium, size, path) };
    defer allocator.free(data);

    const out = buildInlineApc(allocator, apc_bytes, data) catch
        return .{ .refused = Refused.of(.out_of_memory, cmd.medium, size, path) };
    return .{ .inlined = out };
}

/// Byte length of a regular file, or null for anything that cannot be
/// opened or sized (absent, a pipe, most of procfs, an empty file).
fn fileSize(path: []const u8) ?u64 {
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, path) catch return null;
    const fp = c.fopen(p, "rb") orelse return null;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return null;
    const raw = c.ftell(fp);
    if (raw <= 0) return null;
    return @intCast(raw);
}

/// New APC: original control keys minus `t=`, plus `t=d`, payload
/// replaced with base64(data). Textual filtering (not a re-emit of
/// the parsed struct) so keys we don't model survive unchanged.
fn buildInlineApc(allocator: std.mem.Allocator, original: []const u8, data: []const u8) ![]u8 {
    const semi = std.mem.indexOfScalar(u8, original, ';') orelse original.len;
    const control = original[1..semi]; // skip leading 'G'

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(data.len);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, control.len + b64_len + 16);
    try out.append(allocator, 'G');

    var it = std.mem.splitScalar(u8, control, ',');
    while (it.next()) |tok| {
        if (tok.len == 0 or std.mem.startsWith(u8, tok, "t=")) continue;
        try out.appendSlice(allocator, tok);
        try out.append(allocator, ',');
    }
    try out.appendSlice(allocator, "t=d;");

    const start = out.items.len;
    try out.resize(allocator, start + b64_len);
    _ = encoder.encode(out.items[start..], data);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const b64Alloc = @import("../util/b64.zig").encodeAlloc;

/// A tempfile whose name carries the spec marker, so `t=t` may delete it.
fn mkTempWith(contents: []const u8) ![]u8 {
    var tmpl = "/tmp/sketerm-tty-graphics-protocol-XXXXXX".*;
    const fd = c.mkstemp(&tmpl);
    if (fd < 0) return error.TempFailed;
    defer _ = c.close(fd);
    if (c.write(fd, contents.ptr, contents.len) != @as(isize, @intCast(contents.len))) return error.TempFailed;
    return testing.allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(&tmpl))));
}

fn exists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    return c.access(pathZ(&z, path) catch return false, c.F_OK) == 0;
}

fn refusalOf(r: Result) ?Refusal {
    return switch (r) {
        .refused => |x| x.why,
        .inlined => null,
    };
}

test "rewrite: t=f becomes inline t=d, file kept" {
    const a = testing.allocator;
    const path = try mkTempWith("PNGDATA");
    defer {
        pathz.unlinkPath(path);
        a.free(path);
    }
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=100,t=f,a=T,i=7;{s}", .{path_b64});
    defer a.free(apc);

    const out = switch (rewrite(a, apc)) {
        .inlined => |b| b,
        .refused => return error.RewriteFailed,
    };
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "t=d;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "t=f") == null);
    try testing.expect(std.mem.indexOf(u8, out, "i=7") != null);
    const data_b64 = try b64Alloc(a, "PNGDATA");
    defer a.free(data_b64);
    try testing.expect(std.mem.endsWith(u8, out, data_b64));
    // t=f: the file must survive.
    try testing.expect(exists(path));
}

test "rewrite: t=t deletes the marked tempfile after reading" {
    const a = testing.allocator;
    const path = try mkTempWith("TMPDATA");
    defer a.free(path);
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=32,s=1,v=1,t=t,a=T;{s}", .{path_b64});
    defer a.free(apc);

    const out = switch (rewrite(a, apc)) {
        .inlined => |b| b,
        .refused => return error.RewriteFailed,
    };
    defer a.free(out);
    try testing.expect(!exists(path));
}

test "rewrite: t=t never deletes a path without the spec marker" {
    const a = testing.allocator;
    var tmpl = "/tmp/sketerm-kitty-plain-XXXXXX".*;
    const fd = c.mkstemp(&tmpl);
    try testing.expect(fd >= 0);
    try testing.expectEqual(@as(isize, 3), c.write(fd, "RGB", 3));
    _ = c.close(fd);
    defer _ = c.unlink(@ptrCast(&tmpl));
    const path = std.mem.sliceTo(&tmpl, 0);
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=24,s=1,v=1,t=t,a=T;{s}", .{path_b64});
    defer a.free(apc);

    const out = switch (rewrite(a, apc)) {
        .inlined => |b| b,
        .refused => return error.RewriteFailed,
    };
    defer a.free(out);
    // Read and inlined, but the unlink was withheld.
    try testing.expect(exists(path));
}

test "rewrite: an over-cap t=t is refused AND its tempfile is still deleted" {
    const a = testing.allocator;
    const path = try mkTempWith("MORE-THAN-FOUR-BYTES");
    defer {
        pathz.unlinkPath(path);
        a.free(path);
    }
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=32,s=1,v=1,t=t,a=T;{s}", .{path_b64});
    defer a.free(apc);

    const r = rewriteWithCap(a, apc, 4);
    switch (r) {
        .inlined => |b| {
            a.free(b);
            return error.ShouldHaveRefused;
        },
        .refused => |x| {
            try testing.expectEqual(Refusal.too_large, x.why);
            try testing.expectEqual(@as(u64, 20), x.size);
            try testing.expectEqual(@as(u8, 't'), x.medium);
            try testing.expectEqualStrings(path, x.path());
        },
    }
    // The refusal did not leave the tempfile behind: the client never
    // sees a refused APC, so nobody else would have cleaned it up.
    try testing.expect(!exists(path));
}

test "rewrite: an over-cap t=f is refused and the file is kept" {
    const a = testing.allocator;
    const path = try mkTempWith("MORE-THAN-FOUR-BYTES");
    defer {
        pathz.unlinkPath(path);
        a.free(path);
    }
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=100,t=f,a=T;{s}", .{path_b64});
    defer a.free(apc);
    try testing.expectEqual(@as(?Refusal, .too_large), refusalOf(rewriteWithCap(a, apc, 4)));
    try testing.expect(exists(path));
}

test "rewrite: direct and non-kitty APCs are not rewritten" {
    const a = testing.allocator;
    try testing.expectEqual(@as(?Refusal, .not_file_medium), refusalOf(rewrite(a, "Gf=100,t=d,a=T;QUJD")));
    try testing.expectEqual(@as(?Refusal, .not_file_medium), refusalOf(rewrite(a, "not-kitty")));
    // Missing file: refused with a reason, and the caller drops the APC.
    const gone_b64 = try b64Alloc(a, "/nonexistent/sketerm-test");
    defer a.free(gone_b64);
    const apc = try std.fmt.allocPrint(a, "Gt=f,a=T;{s}", .{gone_b64});
    defer a.free(apc);
    try testing.expectEqual(@as(?Refusal, .unreadable), refusalOf(rewrite(a, apc)));
    // A chunked first chunk names a path PREFIX; refused before any
    // filesystem access, so no unlink can be aimed with it.
    try testing.expectEqual(@as(?Refusal, .chunked), refusalOf(rewrite(a, "Gt=t,a=T,m=1;L3RtcC90dHktZ3JhcGhpY3MtcHJvdG9jb2w=")));
    try testing.expectEqual(@as(?Refusal, .bad_path), refusalOf(rewrite(a, "Gt=t,a=T;")));
}

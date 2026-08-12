//! Minimal ZIP reader — enough to unpack an `.xpi` (which is a ZIP) or
//! a `.zip` extension bundle. No in-tree zip reader existed (grepped),
//! so this is a from-scratch one built on `std.compress.flate`, the same
//! decompressor `wlhost/zpool.zig` and `kitty_images.zig` already use.
//!
//! Pure std, no CEF, no GTK, no filesystem: it decodes an in-memory
//! archive into entries, so it is unit-tested headless in both test
//! roots. The caller reads the file and writes the entries to disk.
//!
//! Supported: STORE (method 0) and DEFLATE (method 8), the only two
//! methods any real XPI uses. The archive is parsed from its END — the
//! End Of Central Directory record — which is the only robust way (local
//! headers lie about sizes when a data descriptor follows).

const std = @import("std");

pub const Error = error{
    NotZip,
    Truncated,
    UnsupportedMethod,
    BadData,
    OutOfMemory,
};

pub const Entry = struct {
    /// Path within the archive, forward-slash separated. Borrows from
    /// the archive bytes.
    name: []const u8,
    /// Decompressed contents, owned by the allocator passed to `read`.
    data: []u8,
    /// True for a directory entry (name ends in `/`, zero data).
    is_dir: bool,
};

pub const Archive = struct {
    entries: []Entry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Archive) void {
        for (self.entries) |e| self.gpa.free(e.data);
        self.gpa.free(self.entries);
    }

    /// Find one entry by exact name, or null.
    pub fn find(self: *const Archive, name: []const u8) ?*const Entry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

const eocd_sig: u32 = 0x06054b50;
const cdh_sig: u32 = 0x02014b50;
const lfh_sig: u32 = 0x04034b50;

/// Decode `bytes` (a whole archive) into an owned `Archive`. Every
/// entry's data is decompressed eagerly — extension bundles are small,
/// and a caller that streamed would have to hold the archive anyway.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) Error!Archive {
    const eocd = findEocd(bytes) orelse return error.NotZip;
    const total = readU16(bytes, eocd + 10) orelse return error.Truncated;
    var cd_off = readU32(bytes, eocd + 16) orelse return error.Truncated;

    var list = std.ArrayList(Entry).empty;
    errdefer {
        for (list.items) |e| gpa.free(e.data);
        list.deinit(gpa);
    }

    var i: usize = 0;
    while (i < total) : (i += 1) {
        if (readU32(bytes, cd_off) != cdh_sig) return error.BadData;
        const method = readU16(bytes, cd_off + 10) orelse return error.Truncated;
        const comp_size = readU32(bytes, cd_off + 20) orelse return error.Truncated;
        const uncomp_size = readU32(bytes, cd_off + 24) orelse return error.Truncated;
        const name_len = readU16(bytes, cd_off + 28) orelse return error.Truncated;
        const extra_len = readU16(bytes, cd_off + 30) orelse return error.Truncated;
        const comment_len = readU16(bytes, cd_off + 32) orelse return error.Truncated;
        const lfh_off = readU32(bytes, cd_off + 42) orelse return error.Truncated;
        const name_start = cd_off + 46;
        if (name_start + name_len > bytes.len) return error.Truncated;
        const name = bytes[name_start .. name_start + name_len];

        const data = try extractLocal(gpa, bytes, lfh_off, method, comp_size, uncomp_size);
        try list.append(gpa, .{
            .name = name,
            .data = data,
            .is_dir = name.len > 0 and name[name.len - 1] == '/',
        });

        cd_off = name_start + name_len + extra_len + comment_len;
        if (cd_off > bytes.len) return error.Truncated;
    }

    return .{ .entries = try list.toOwnedSlice(gpa), .gpa = gpa };
}

/// Extract one entry's bytes given its LOCAL file header offset (the
/// central directory's sizes are authoritative; the local header's may
/// be zero when a data descriptor trails).
fn extractLocal(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    lfh_off: u32,
    method: u16,
    comp_size: u32,
    uncomp_size: u32,
) Error![]u8 {
    if (readU32(bytes, lfh_off) != lfh_sig) return error.BadData;
    const name_len = readU16(bytes, lfh_off + 26) orelse return error.Truncated;
    const extra_len = readU16(bytes, lfh_off + 28) orelse return error.Truncated;
    const data_off = lfh_off + 30 + name_len + extra_len;
    if (data_off + comp_size > bytes.len) return error.Truncated;
    const comp = bytes[data_off .. data_off + comp_size];

    switch (method) {
        0 => {
            // STORE: comp_size must equal uncomp_size.
            if (comp_size != uncomp_size) return error.BadData;
            return gpa.dupe(u8, comp) catch return error.OutOfMemory;
        },
        8 => {
            const out = gpa.alloc(u8, uncomp_size) catch return error.OutOfMemory;
            errdefer gpa.free(out);
            if (uncomp_size == 0) return out;
            var in = std.Io.Reader.fixed(comp);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d = std.compress.flate.Decompress.init(&in, .raw, &window);
            const n = d.reader.readSliceShort(out) catch return error.BadData;
            if (n != uncomp_size) return error.BadData;
            return out;
        },
        else => return error.UnsupportedMethod,
    }
}

/// Scan backwards for the End Of Central Directory signature. The EOCD
/// is at the very end save for an optional trailing comment (max 64KB),
/// so a bounded backward scan finds it.
fn findEocd(bytes: []const u8) ?usize {
    if (bytes.len < 22) return null;
    const min_from = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
    var i = bytes.len - 22;
    while (true) : (i -= 1) {
        if (readU32(bytes, i) == eocd_sig) return i;
        if (i == min_from) return null;
    }
}

fn readU16(bytes: []const u8, off: usize) ?u16 {
    if (off + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) ?u32 {
    if (off + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

// ─── tests ──────────────────────────────────────────────────────────
//
// Building a real ZIP in-memory keeps the reader honest against the
// exact byte layout — a fixture file would hide an off-by-one.

const t = std.testing;

const TestFile = struct { name: []const u8, data: []const u8, deflate: bool };

/// Assemble a minimal but spec-valid zip of `files`. Deflate entries
/// are raw-deflate compressed with std, store entries copied verbatim.
fn buildZip(gpa: std.mem.Allocator, files: []const TestFile) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    const Local = struct { off: u32, crc: u32, comp: u32, uncomp: u32, method: u16, name: []const u8 };
    var locals = std.ArrayList(Local).empty;
    defer locals.deinit(gpa);

    for (files) |f| {
        const off: u32 = @intCast(out.items.len);
        const crc = std.hash.crc.Crc32.hash(f.data);
        var comp_bytes: []u8 = undefined;
        var method: u16 = 0;
        if (f.deflate) {
            var dst: [16 * 1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&dst);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var comp = try std.compress.flate.Compress.init(&w, &window, .raw, .default);
            try comp.writer.writeAll(f.data);
            try comp.finish();
            comp_bytes = try gpa.dupe(u8, w.buffered());
            method = 8;
        } else {
            comp_bytes = try gpa.dupe(u8, f.data);
        }
        defer gpa.free(comp_bytes);

        try putU32(gpa, &out, lfh_sig);
        try putU16(gpa, &out, 20); // version needed
        try putU16(gpa, &out, 0); // flags
        try putU16(gpa, &out, method);
        try putU16(gpa, &out, 0); // time
        try putU16(gpa, &out, 0); // date
        try putU32(gpa, &out, crc);
        try putU32(gpa, &out, @intCast(comp_bytes.len));
        try putU32(gpa, &out, @intCast(f.data.len));
        try putU16(gpa, &out, @intCast(f.name.len));
        try putU16(gpa, &out, 0); // extra len
        try out.appendSlice(gpa, f.name);
        try out.appendSlice(gpa, comp_bytes);

        try locals.append(gpa, .{
            .off = off,
            .crc = crc,
            .comp = @intCast(comp_bytes.len),
            .uncomp = @intCast(f.data.len),
            .method = method,
            .name = f.name,
        });
    }

    const cd_start: u32 = @intCast(out.items.len);
    for (locals.items) |l| {
        try putU32(gpa, &out, cdh_sig);
        try putU16(gpa, &out, 20); // version made by
        try putU16(gpa, &out, 20); // version needed
        try putU16(gpa, &out, 0); // flags
        try putU16(gpa, &out, l.method);
        try putU16(gpa, &out, 0);
        try putU16(gpa, &out, 0);
        try putU32(gpa, &out, l.crc);
        try putU32(gpa, &out, l.comp);
        try putU32(gpa, &out, l.uncomp);
        try putU16(gpa, &out, @intCast(l.name.len));
        try putU16(gpa, &out, 0); // extra
        try putU16(gpa, &out, 0); // comment
        try putU16(gpa, &out, 0); // disk
        try putU16(gpa, &out, 0); // internal attrs
        try putU32(gpa, &out, 0); // external attrs
        try putU32(gpa, &out, l.off);
        try out.appendSlice(gpa, l.name);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_start);

    try putU32(gpa, &out, eocd_sig);
    try putU16(gpa, &out, 0); // disk
    try putU16(gpa, &out, 0); // cd disk
    try putU16(gpa, &out, @intCast(locals.items.len));
    try putU16(gpa, &out, @intCast(locals.items.len));
    try putU32(gpa, &out, cd_size);
    try putU32(gpa, &out, cd_start);
    try putU16(gpa, &out, 0); // comment len

    return out.toOwnedSlice(gpa);
}

fn putU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}
fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

test "reads store and deflate entries" {
    const gpa = t.allocator;
    const long = "manifest content " ** 40; // compressible payload
    const zip = try buildZip(gpa, &.{
        .{ .name = "manifest.json", .data = "{\"name\":\"x\"}", .deflate = false },
        .{ .name = "bg.js", .data = long, .deflate = true },
        .{ .name = "dir/", .data = "", .deflate = false },
    });
    defer gpa.free(zip);

    var arc = try read(gpa, zip);
    defer arc.deinit();
    try t.expectEqual(@as(usize, 3), arc.entries.len);

    const man = arc.find("manifest.json").?;
    try t.expectEqualStrings("{\"name\":\"x\"}", man.data);
    try t.expect(!man.is_dir);

    const bg = arc.find("bg.js").?;
    try t.expectEqualStrings(long, bg.data);

    const dir = arc.find("dir/").?;
    try t.expect(dir.is_dir);
    try t.expectEqual(@as(usize, 0), dir.data.len);
}

test "rejects non-zip bytes" {
    const gpa = t.allocator;
    try t.expectError(error.NotZip, read(gpa, "not a zip file at all"));
    try t.expectError(error.NotZip, read(gpa, ""));
}

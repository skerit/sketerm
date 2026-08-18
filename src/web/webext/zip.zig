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
    LimitExceeded,
    UnsafeName,
    DuplicateName,
    ChecksumMismatch,
    UnsupportedZip64,
    OutOfMemory,
};

pub const limits = struct {
    pub const archive_size: usize = 64 * 1024 * 1024;
    pub const entries: usize = 8192;
    pub const entry_uncompressed: usize = 64 * 1024 * 1024;
    pub const aggregate_uncompressed: usize = 256 * 1024 * 1024;
    pub const name_length: usize = 1024;
    /// Path components one entry name may have. Unpacking and cleanup
    /// walk the installed tree, so archive depth is stack depth: 1024
    /// bytes of name buys ~512 levels, enough to overflow the main
    /// thread's stack mid-install. No real extension is anywhere near.
    pub const name_depth: usize = 32;
    // There is deliberately no per-entry compression-ratio bound. Deflate
    // tops out near 1032:1, bundler source maps sit at ~400:1 (measured),
    // and entry_uncompressed + aggregate_uncompressed already cap the
    // work a bomb can cause; a ratio check can only add false positives.
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
const data_descriptor_flag: u16 = 1 << 3;
const encrypted_flags: u16 = (1 << 0) | (1 << 6) | (1 << 13);

const Pending = struct {
    name: []const u8,
    comp: []const u8 = &.{},
    comp_size: usize,
    uncomp_size: usize,
    lfh_off: usize,
    crc: u32,
    flags: u16,
    method: u16,
    is_dir: bool,
};

/// Decode a bounded, single-disk ZIP archive into owned entries.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) Error!Archive {
    if (bytes.len > limits.archive_size) return error.LimitExceeded;

    const eocd_off = try findEocd(bytes);
    const eocd = try range(bytes, eocd_off, 22, bytes.len);
    const disk = le16(eocd, 4);
    const cd_disk = le16(eocd, 6);
    const disk_entries = le16(eocd, 8);
    const total_u16 = le16(eocd, 10);
    const cd_size_u32 = le32(eocd, 12);
    const cd_off_u32 = le32(eocd, 16);
    if (disk != 0 or cd_disk != 0 or disk_entries != total_u16) return error.BadData;
    if (total_u16 == std.math.maxInt(u16) or
        cd_size_u32 == std.math.maxInt(u32) or
        cd_off_u32 == std.math.maxInt(u32)) return error.UnsupportedZip64;

    const total: usize = total_u16;
    if (total > limits.entries) return error.LimitExceeded;
    const cd_size = toUsize(cd_size_u32) orelse return error.BadData;
    const cd_start = toUsize(cd_off_u32) orelse return error.BadData;
    _ = try range(bytes, cd_start, cd_size, eocd_off);
    const cd_end = std.math.add(usize, cd_start, cd_size) catch return error.BadData;

    var pending = std.ArrayList(Pending).empty;
    defer pending.deinit(gpa);
    pending.ensureTotalCapacity(gpa, total) catch return error.OutOfMemory;

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);

    var aggregate: usize = 0;
    var cd_cursor = cd_start;
    for (0..total) |_| {
        const header = try consume(bytes, &cd_cursor, 46, cd_end);
        if (le32(header, 0) != cdh_sig) return error.BadData;
        const flags = le16(header, 8);
        const method = le16(header, 10);
        const crc = le32(header, 16);
        const comp_u32 = le32(header, 20);
        const uncomp_u32 = le32(header, 24);
        const name_len: usize = le16(header, 28);
        const extra_len: usize = le16(header, 30);
        const comment_len: usize = le16(header, 32);
        const disk_start = le16(header, 34);
        const lfh_u32 = le32(header, 42);

        if (flags & encrypted_flags != 0 or disk_start != 0) return error.BadData;
        if (method != 0 and method != 8) return error.UnsupportedMethod;
        if (comp_u32 == std.math.maxInt(u32) or
            uncomp_u32 == std.math.maxInt(u32) or
            lfh_u32 == std.math.maxInt(u32)) return error.UnsupportedZip64;
        if (name_len > limits.name_length) return error.LimitExceeded;

        const name = try consume(bytes, &cd_cursor, name_len, cd_end);
        _ = try consume(bytes, &cd_cursor, extra_len, cd_end);
        _ = try consume(bytes, &cd_cursor, comment_len, cd_end);
        const is_dir = try validateName(name);
        if (names.contains(name)) return error.DuplicateName;
        names.put(gpa, name, {}) catch return error.OutOfMemory;

        const comp_size = toUsize(comp_u32) orelse return error.BadData;
        const uncomp_size = toUsize(uncomp_u32) orelse return error.BadData;
        if (uncomp_size > limits.entry_uncompressed) return error.LimitExceeded;
        aggregate = std.math.add(usize, aggregate, uncomp_size) catch return error.LimitExceeded;
        if (aggregate > limits.aggregate_uncompressed) return error.LimitExceeded;
        if (is_dir and uncomp_size != 0) return error.BadData;

        pending.appendAssumeCapacity(.{
            .name = name,
            .comp_size = comp_size,
            .uncomp_size = uncomp_size,
            .lfh_off = toUsize(lfh_u32) orelse return error.BadData,
            .crc = crc,
            .flags = flags,
            .method = method,
            .is_dir = is_dir,
        });
    }
    if (cd_cursor != cd_end) return error.BadData;

    for (pending.items) |*entry| {
        try validateSizes(entry.method, entry.comp_size, entry.uncomp_size);
        entry.comp = try localData(bytes, cd_start, entry);
    }

    const entries = gpa.alloc(Entry, pending.items.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| gpa.free(entry.data);
        gpa.free(entries);
    }
    for (pending.items) |entry| {
        const data = try extract(gpa, entry.comp, entry.method, entry.uncomp_size, entry.crc);
        entries[initialized] = .{ .name = entry.name, .data = data, .is_dir = entry.is_dir };
        initialized += 1;
    }
    return .{ .entries = entries, .gpa = gpa };
}

fn localData(
    bytes: []const u8,
    cd_start: usize,
    entry: *const Pending,
) Error![]const u8 {
    var cursor = entry.lfh_off;
    const header = try consume(bytes, &cursor, 30, cd_start);
    if (le32(header, 0) != lfh_sig) return error.BadData;
    const flags = le16(header, 6);
    const method = le16(header, 8);
    const crc = le32(header, 14);
    const comp_size = le32(header, 18);
    const uncomp_size = le32(header, 22);
    const name_len: usize = le16(header, 26);
    const extra_len: usize = le16(header, 28);
    if (flags != entry.flags or method != entry.method) return error.BadData;
    if (name_len > limits.name_length) return error.LimitExceeded;

    const name = try consume(bytes, &cursor, name_len, cd_start);
    if (!std.mem.eql(u8, name, entry.name)) return error.BadData;
    _ = try consume(bytes, &cursor, extra_len, cd_start);

    const local_comp_size = toUsize(comp_size) orelse return error.BadData;
    const local_uncomp_size = toUsize(uncomp_size) orelse return error.BadData;

    if (flags & data_descriptor_flag == 0) {
        if (crc != entry.crc or local_comp_size != entry.comp_size or local_uncomp_size != entry.uncomp_size)
            return error.BadData;
    } else {
        if ((crc != 0 and crc != entry.crc) or
            (local_comp_size != 0 and local_comp_size != entry.comp_size) or
            (local_uncomp_size != 0 and local_uncomp_size != entry.uncomp_size)) return error.BadData;
    }
    return consume(bytes, &cursor, entry.comp_size, cd_start);
}

fn extract(
    gpa: std.mem.Allocator,
    comp: []const u8,
    method: u16,
    uncomp_size: usize,
    expected_crc: u32,
) Error![]u8 {
    const out = switch (method) {
        0 => gpa.dupe(u8, comp) catch return error.OutOfMemory,
        8 => blk: {
            const out = gpa.alloc(u8, uncomp_size) catch return error.OutOfMemory;
            errdefer gpa.free(out);
            var in = std.Io.Reader.fixed(comp);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d = std.compress.flate.Decompress.init(&in, .raw, &window);
            const n = d.reader.readSliceShort(out) catch return error.BadData;
            if (n != uncomp_size) return error.BadData;
            var probe: [1]u8 = undefined;
            const extra = d.reader.readSliceShort(&probe) catch return error.BadData;
            if (extra != 0 or in.bufferedLen() != 0) return error.BadData;
            break :blk out;
        },
        else => return error.UnsupportedMethod,
    };
    errdefer gpa.free(out);
    if (std.hash.crc.Crc32.hash(out) != expected_crc) return error.ChecksumMismatch;
    return out;
}

fn validateSizes(method: u16, comp_size: usize, uncomp_size: usize) Error!void {
    if (method == 0) {
        if (comp_size != uncomp_size) return error.BadData;
        return;
    }
    if (uncomp_size != 0 and comp_size == 0) return error.BadData;
}

/// Apply the archive entry path policy without extracting an entry.
pub fn validateName(name: []const u8) Error!bool {
    if (name.len == 0 or name.len > limits.name_length) return error.UnsafeName;
    if (name[0] == '/' or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, name, '\\') != null or
        (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':'))
        return error.UnsafeName;

    const is_dir = name[name.len - 1] == '/';
    const path = if (is_dir) name[0 .. name.len - 1] else name;
    if (path.len == 0) return error.UnsafeName;
    var components = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.UnsafeName;
        depth += 1;
        if (depth > limits.name_depth) return error.UnsafeName;
    }
    return is_dir;
}

/// Find an EOCD whose declared comment reaches the exact archive end.
fn findEocd(bytes: []const u8) Error!usize {
    if (bytes.len < 22) return error.NotZip;
    const min_from = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
    var i = bytes.len - 22;
    var saw_signature = false;
    while (true) {
        if (readU32(bytes, i) == eocd_sig) {
            saw_signature = true;
            const candidate = try range(bytes, i, 22, bytes.len);
            const comment_len = le16(candidate, 20);
            if (comment_len == bytes.len - i - 22) return i;
        }
        if (i == min_from) break;
        i -= 1;
    }
    return if (saw_signature) error.BadData else error.NotZip;
}

fn range(bytes: []const u8, off: usize, len: usize, limit: usize) Error![]const u8 {
    if (limit > bytes.len or off > limit or len > limit - off) return error.Truncated;
    return bytes[off .. off + len];
}

fn consume(bytes: []const u8, cursor: *usize, len: usize, limit: usize) Error![]const u8 {
    const result = try range(bytes, cursor.*, len, limit);
    cursor.* = std.math.add(usize, cursor.*, len) catch return error.BadData;
    return result;
}

fn toUsize(value: anytype) ?usize {
    return std.math.cast(usize, value);
}

fn le16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn le32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU16(bytes: []const u8, off: usize) ?u16 {
    if (off > bytes.len or bytes.len - off < 2) return null;
    return le16(bytes, off);
}

fn readU32(bytes: []const u8, off: usize) ?u32 {
    if (off > bytes.len or bytes.len - off < 4) return null;
    return le32(bytes, off);
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

fn setU16(bytes: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[off..][0..2], value, .little);
}

fn setU32(bytes: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], value, .little);
}

fn testEocdOffset(zip: []const u8) usize {
    return zip.len - 22 - readU16(zip, zip.len - 2).?;
}

fn testCentralOffset(zip: []const u8, index: usize) usize {
    var cursor: usize = readU32(zip, testEocdOffset(zip) + 16).?;
    for (0..index) |_| {
        cursor += 46 + readU16(zip, cursor + 28).? +
            readU16(zip, cursor + 30).? + readU16(zip, cursor + 32).?;
    }
    return cursor;
}

fn testLocalOffset(zip: []const u8, central: usize) usize {
    return readU32(zip, central + 42).?;
}

test "reads store and deflate entries" {
    const gpa = t.allocator;
    const long = "manifest content " ** 40; // compressible payload
    const zip = try buildZip(gpa, &.{
        .{ .name = "manifest.json", .data = "{\"name\":\"x\"}", .deflate = false },
        .{ .name = "bg.js", .data = long, .deflate = true },
        .{ .name = "dir/", .data = "", .deflate = false },
        .{ .name = "compressed-dir/", .data = "", .deflate = true },
    });
    defer gpa.free(zip);

    var arc = try read(gpa, zip);
    defer arc.deinit();
    try t.expectEqual(@as(usize, 4), arc.entries.len);

    const man = arc.find("manifest.json").?;
    try t.expectEqualStrings("{\"name\":\"x\"}", man.data);
    try t.expect(!man.is_dir);

    const bg = arc.find("bg.js").?;
    try t.expectEqualStrings(long, bg.data);

    const dir = arc.find("dir/").?;
    try t.expect(dir.is_dir);
    try t.expectEqual(@as(usize, 0), dir.data.len);

    const compressed_dir = arc.find("compressed-dir/").?;
    try t.expect(compressed_dir.is_dir);
    try t.expectEqual(@as(usize, 0), compressed_dir.data.len);
}

test "accepts an EOCD comment and data descriptor metadata" {
    const gpa = t.allocator;
    const original = try buildZip(gpa, &.{
        .{ .name = "manifest.json", .data = "{\"name\":\"descriptor\"}", .deflate = true },
    });
    defer gpa.free(original);

    const old_cd = testCentralOffset(original, 0);
    const old_eocd = testEocdOffset(original);
    const descriptor_len = 16;
    const comment = "xpi comment";
    const zip = try gpa.alloc(u8, original.len + descriptor_len + comment.len);
    defer gpa.free(zip);
    @memcpy(zip[0..old_cd], original[0..old_cd]);
    @memcpy(zip[old_cd + descriptor_len ..][0 .. original.len - old_cd], original[old_cd..]);

    const moved_cd = old_cd + descriptor_len;
    const moved_eocd = old_eocd + descriptor_len;
    const crc = readU32(original, old_cd + 16).?;
    const comp_size = readU32(original, old_cd + 20).?;
    const uncomp_size = readU32(original, old_cd + 24).?;
    setU32(zip, old_cd, 0x08074b50);
    setU32(zip, old_cd + 4, crc);
    setU32(zip, old_cd + 8, comp_size);
    setU32(zip, old_cd + 12, uncomp_size);
    setU16(zip, 6, data_descriptor_flag);
    setU32(zip, 14, 0);
    setU32(zip, 18, 0);
    setU32(zip, 22, 0);
    setU16(zip, moved_cd + 8, data_descriptor_flag);
    setU32(zip, moved_eocd + 16, @intCast(moved_cd));
    setU16(zip, moved_eocd + 20, @intCast(comment.len));
    @memcpy(zip[moved_eocd + 22 ..], comment);

    var arc = try read(gpa, zip);
    defer arc.deinit();
    try t.expectEqualStrings("{\"name\":\"descriptor\"}", arc.find("manifest.json").?.data);
}

test "rejects entry count, output size, and aggregate bombs" {
    const gpa = t.allocator;

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const eocd = testEocdOffset(zip);
        setU16(zip, eocd + 8, @intCast(limits.entries + 1));
        setU16(zip, eocd + 10, @intCast(limits.entries + 1));
        try t.expectError(error.LimitExceeded, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const central = testCentralOffset(zip, 0);
        const local = testLocalOffset(zip, central);
        setU32(zip, central + 24, @intCast(limits.entry_uncompressed + 1));
        setU32(zip, local + 22, @intCast(limits.entry_uncompressed + 1));
        try t.expectError(error.LimitExceeded, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{
            .{ .name = "a", .data = "x", .deflate = false },
            .{ .name = "b", .data = "x", .deflate = false },
            .{ .name = "c", .data = "x", .deflate = false },
            .{ .name = "d", .data = "x", .deflate = false },
            .{ .name = "e", .data = "x", .deflate = false },
        });
        defer gpa.free(zip);
        for (0..5) |i| {
            const central = testCentralOffset(zip, i);
            const local = testLocalOffset(zip, central);
            setU32(zip, central + 24, @intCast(limits.entry_uncompressed));
            setU32(zip, local + 22, @intCast(limits.entry_uncompressed));
        }
        try t.expectError(error.LimitExceeded, read(gpa, zip));
    }

}

test "accepts a maximally compressible entry" {
    // A source map or a zero-filled buffer is a legitimate ~400:1..1032:1
    // entry; the size caps, not a ratio, are what bound bombs here.
    const gpa = t.allocator;
    const size: usize = 8 * 1024 * 1024;
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    @memset(data, 0);
    const zip = try buildZip(gpa, &.{.{ .name = "map.js.map", .data = data, .deflate = true }});
    defer gpa.free(zip);
    // Sanity: the entry really is extreme (>= 400:1), else this proves nothing.
    const cd_off = le32(zip, zip.len - 22 + 16);
    try t.expect(le32(zip, cd_off + 20) * 400 <= size);
    var arc = try read(gpa, zip);
    defer arc.deinit();
    try t.expectEqual(size, arc.find("map.js.map").?.data.len);
}

test "reports Zip64 sentinels as unsupported, not corrupt" {
    const gpa = t.allocator;
    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU32(zip, zip.len - 22 + 12, std.math.maxInt(u32));
        try t.expectError(error.UnsupportedZip64, read(gpa, zip));
    }
    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const cd_off = le32(zip, zip.len - 22 + 16);
        setU32(zip, cd_off + 24, std.math.maxInt(u32));
        try t.expectError(error.UnsupportedZip64, read(gpa, zip));
    }
}

test "rejects overlong, duplicate, and unsafe names" {
    const gpa = t.allocator;

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU16(zip, testCentralOffset(zip, 0) + 28, @intCast(limits.name_length + 1));
        try t.expectError(error.LimitExceeded, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{
            .{ .name = "manifest.json", .data = "one", .deflate = false },
            .{ .name = "manifest.json", .data = "two", .deflate = true },
        });
        defer gpa.free(zip);
        try t.expectError(error.DuplicateName, read(gpa, zip));
    }

    for ([_][]const u8{
        "../manifest.json",
        "dir/../manifest.json",
        "/manifest.json",
        "C:/manifest.json",
        "dir\\manifest.json",
        "./manifest.json",
        "dir//manifest.json",
        "\x00manifest.json",
    }) |name| {
        const zip = try buildZip(gpa, &.{.{ .name = name, .data = "x", .deflate = false }});
        defer gpa.free(zip);
        try t.expectError(error.UnsafeName, read(gpa, zip));
    }

    // Depth, not just length: `a/a/.../x` fits well inside the name
    // budget while nesting deep enough to overflow the stack of anything
    // that walks the unpacked tree.
    {
        var deep: std.ArrayList(u8) = .empty;
        defer deep.deinit(gpa);
        for (0..limits.name_depth) |_| try deep.appendSlice(gpa, "a/");
        try deep.appendSlice(gpa, "x");
        try t.expect(deep.items.len <= limits.name_length);
        try t.expectError(error.UnsafeName, validateName(deep.items));
        const zip = try buildZip(gpa, &.{.{ .name = deep.items, .data = "x", .deflate = false }});
        defer gpa.free(zip);
        try t.expectError(error.UnsafeName, read(gpa, zip));
    }

    // One component under the cap still installs.
    {
        var ok_name: std.ArrayList(u8) = .empty;
        defer ok_name.deinit(gpa);
        for (0..limits.name_depth - 1) |_| try ok_name.appendSlice(gpa, "a/");
        try ok_name.appendSlice(gpa, "x");
        try t.expect(!try validateName(ok_name.items));
    }
}

test "rejects malformed EOCD and central directory extents" {
    const gpa = t.allocator;

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU16(zip, testEocdOffset(zip) + 20, 1);
        try t.expectError(error.BadData, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const eocd = testEocdOffset(zip);
        setU32(zip, eocd + 12, 0x40);
        setU32(zip, eocd + 16, 0xfffffff0);
        try t.expectError(error.Truncated, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU16(zip, testCentralOffset(zip, 0) + 30, 1);
        try t.expectError(error.Truncated, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const eocd = testEocdOffset(zip);
        setU32(zip, eocd + 12, 45);
        try t.expectError(error.Truncated, read(gpa, zip));
    }
}

test "rejects checked arithmetic and local extent overflow" {
    const gpa = t.allocator;
    try t.expectError(error.Truncated, range("abc", std.math.maxInt(usize) - 1, 4, 3));
    var cursor: usize = std.math.maxInt(usize) - 1;
    try t.expectError(error.Truncated, consume("abc", &cursor, 4, 3));

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU32(zip, testCentralOffset(zip, 0) + 42, 0xfffffff0);
        try t.expectError(error.Truncated, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "contents", .deflate = true }});
        defer gpa.free(zip);
        const central = testCentralOffset(zip, 0);
        const local = testLocalOffset(zip, central);
        const too_large = readU32(zip, central + 20).? + 1;
        setU32(zip, central + 20, too_large);
        setU32(zip, local + 18, too_large);
        try t.expectError(error.Truncated, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU16(zip, 28, 0xffff);
        try t.expectError(error.Truncated, read(gpa, zip));
    }
}

test "rejects local and central metadata disagreement" {
    const gpa = t.allocator;

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU16(zip, 8, 8);
        try t.expectError(error.BadData, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        zip[30] = 'b';
        try t.expectError(error.BadData, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        setU32(zip, 18, 2);
        try t.expectError(error.BadData, read(gpa, zip));
    }
}

test "requires exact deflate output and compressed EOF" {
    const gpa = t.allocator;
    const data = "deflate output with enough bytes to detect both mismatch directions";

    for ([_]u32{ data.len - 1, data.len + 1 }) |declared| {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = data, .deflate = true }});
        defer gpa.free(zip);
        const central = testCentralOffset(zip, 0);
        const local = testLocalOffset(zip, central);
        setU32(zip, central + 24, declared);
        setU32(zip, local + 22, declared);
        try t.expectError(error.BadData, read(gpa, zip));
    }

    const original = try buildZip(gpa, &.{.{ .name = "a", .data = data, .deflate = true }});
    defer gpa.free(original);
    const old_cd = testCentralOffset(original, 0);
    const old_eocd = testEocdOffset(original);
    const zip = try gpa.alloc(u8, original.len + 1);
    defer gpa.free(zip);
    @memcpy(zip[0..old_cd], original[0..old_cd]);
    zip[old_cd] = 0;
    @memcpy(zip[old_cd + 1 ..], original[old_cd..]);
    const moved_cd = old_cd + 1;
    const moved_eocd = old_eocd + 1;
    const comp_size = readU32(original, old_cd + 20).? + 1;
    setU32(zip, 18, comp_size);
    setU32(zip, moved_cd + 20, comp_size);
    setU32(zip, moved_eocd + 16, @intCast(moved_cd));
    try t.expectError(error.BadData, read(gpa, zip));
}

test "rejects CRC mismatch and unsupported compression methods" {
    const gpa = t.allocator;

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const central = testCentralOffset(zip, 0);
        const local = testLocalOffset(zip, central);
        const wrong_crc = readU32(zip, central + 16).? ^ 1;
        setU32(zip, central + 16, wrong_crc);
        setU32(zip, local + 14, wrong_crc);
        try t.expectError(error.ChecksumMismatch, read(gpa, zip));
    }

    {
        const zip = try buildZip(gpa, &.{.{ .name = "a", .data = "x", .deflate = false }});
        defer gpa.free(zip);
        const central = testCentralOffset(zip, 0);
        const local = testLocalOffset(zip, central);
        setU16(zip, central + 10, 99);
        setU16(zip, local + 8, 99);
        try t.expectError(error.UnsupportedMethod, read(gpa, zip));
    }
}

test "rejects non-zip bytes" {
    const gpa = t.allocator;
    try t.expectError(error.NotZip, read(gpa, "not a zip file at all"));
    try t.expectError(error.NotZip, read(gpa, ""));
}

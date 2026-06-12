//! Wayland wire-format codec (pure Zig, no libc, no GTK).
//!
//! Shared by both ends of the sketerm-native app pipe: the daemon's
//! per-session Wayland endpoint (fd/buffer interception) and the
//! GUI's compositor brain. Knows ONLY the byte format — interface
//! and message semantics live in protocol.zig.
//!
//! Format (host byte order, the connecting app is always local to
//! the socket so endianness never crosses a machine boundary):
//!   header: u32 object id, u32 (size << 16 | opcode), size
//!           includes the 8-byte header and is 32-bit aligned.
//!   args:   i/u/f/o/n = one 32-bit word
//!           s = u32 len (incl. NUL) + bytes padded to 4; len 0 = null
//!           a = u32 len + bytes padded to 4
//!           h = NOTHING in the byte stream (fd rides SCM_RIGHTS)

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

pub const header_size = 8;

pub const Header = struct {
    object: u32,
    opcode: u16,
    /// Total message size including the header.
    size: u16,
};

pub const Error = error{ Malformed, NoSpace };

/// Null when fewer than 8 bytes are available (caller buffers more).
/// error.Malformed when the size field is impossible.
pub fn parseHeader(bytes: []const u8) Error!?Header {
    if (bytes.len < header_size) return null;
    const object = std.mem.readInt(u32, bytes[0..4], native_endian);
    const word = std.mem.readInt(u32, bytes[4..8], native_endian);
    const size: u16 = @intCast(word >> 16);
    if (size < header_size or size % 4 != 0) return Error.Malformed;
    return .{
        .object = object,
        .opcode = @intCast(word & 0xffff),
        .size = size,
    };
}

/// One decoded argument. `fd` is a placeholder: file descriptors
/// travel out-of-band (SCM_RIGHTS) and the caller pairs them up in
/// order via protocol.fdCount().
pub const Arg = union(enum) {
    int: i32,
    uint: u32,
    /// 24.8 signed fixed point; see fixedToF64.
    fixed: i32,
    /// Null = absent (wire length 0). Slice excludes the NUL.
    string: ?[]const u8,
    /// Object id; 0 = null object.
    object: u32,
    new_id: u32,
    array: []const u8,
    fd,
};

/// Walks a message body against a protocol.zig signature string.
/// `body` is the message WITHOUT the 8-byte header.
pub const ArgIter = struct {
    body: []const u8,
    sig: []const u8,
    pos: usize = 0,
    sig_pos: usize = 0,

    pub fn init(body: []const u8, sig: []const u8) ArgIter {
        return .{ .body = body, .sig = sig };
    }

    /// Null when the signature is exhausted. error.Malformed when
    /// the body is shorter than the signature demands or a string
    /// is missing its NUL.
    pub fn next(self: *ArgIter) Error!?Arg {
        while (self.sig_pos < self.sig.len and self.sig[self.sig_pos] == '?')
            self.sig_pos += 1;
        if (self.sig_pos >= self.sig.len) return null;
        const ch = self.sig[self.sig_pos];
        self.sig_pos += 1;
        switch (ch) {
            'i' => return .{ .int = @bitCast(try self.word()) },
            'u' => return .{ .uint = try self.word() },
            'f' => return .{ .fixed = @bitCast(try self.word()) },
            'o' => return .{ .object = try self.word() },
            'n' => return .{ .new_id = try self.word() },
            's' => {
                const len = try self.word();
                if (len == 0) return .{ .string = null };
                const bytes = try self.padded(len);
                if (bytes[len - 1] != 0) return Error.Malformed;
                return .{ .string = bytes[0 .. len - 1] };
            },
            'a' => {
                const len = try self.word();
                return .{ .array = try self.padded(len) };
            },
            'h' => return .fd,
            else => return Error.Malformed,
        }
    }

    fn word(self: *ArgIter) Error!u32 {
        if (self.pos + 4 > self.body.len) return Error.Malformed;
        const v = std.mem.readInt(u32, self.body[self.pos..][0..4], native_endian);
        self.pos += 4;
        return v;
    }

    fn padded(self: *ArgIter, len: u32) Error![]const u8 {
        const total = (@as(usize, len) + 3) & ~@as(usize, 3);
        if (self.pos + total > self.body.len) return Error.Malformed;
        const bytes = self.body[self.pos .. self.pos + len];
        self.pos += total;
        return bytes;
    }
};

/// Serializes one message into a caller-owned buffer. finish()
/// patches the size word and returns the encoded slice.
pub const Builder = struct {
    buf: []u8,
    len: usize,
    err: bool = false,

    pub fn init(buf: []u8, object: u32, opcode: u16) Builder {
        var b = Builder{ .buf = buf, .len = header_size };
        if (buf.len < header_size) {
            b.err = true;
            return b;
        }
        std.mem.writeInt(u32, buf[0..4], object, native_endian);
        std.mem.writeInt(u32, buf[4..8], opcode, native_endian);
        return b;
    }

    pub fn putInt(self: *Builder, v: i32) void {
        self.putWord(@bitCast(v));
    }

    pub fn putUint(self: *Builder, v: u32) void {
        self.putWord(v);
    }

    pub fn putFixed(self: *Builder, v: i32) void {
        self.putWord(@bitCast(v));
    }

    pub fn putObject(self: *Builder, id: u32) void {
        self.putWord(id);
    }

    pub fn putNewId(self: *Builder, id: u32) void {
        self.putWord(id);
    }

    pub fn putString(self: *Builder, s: ?[]const u8) void {
        const str = s orelse {
            self.putWord(0);
            return;
        };
        const len: u32 = @intCast(str.len + 1); // wire length includes NUL
        self.putWord(len);
        self.putPadded(str, 1);
    }

    pub fn putArray(self: *Builder, a: []const u8) void {
        self.putWord(@intCast(a.len));
        self.putPadded(a, 0);
    }

    /// Patches the size word. error.NoSpace when any put overflowed
    /// the buffer (the message is unusable then).
    pub fn finish(self: *Builder) Error![]const u8 {
        if (self.err or self.len > 0xffff) return Error.NoSpace;
        const opcode = std.mem.readInt(u32, self.buf[4..8], native_endian) & 0xffff;
        const word = (@as(u32, @intCast(self.len)) << 16) | opcode;
        std.mem.writeInt(u32, self.buf[4..8], word, native_endian);
        return self.buf[0..self.len];
    }

    fn putWord(self: *Builder, v: u32) void {
        if (self.err or self.len + 4 > self.buf.len) {
            self.err = true;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, native_endian);
        self.len += 4;
    }

    fn putPadded(self: *Builder, bytes: []const u8, nul: usize) void {
        const total = (bytes.len + nul + 3) & ~@as(usize, 3);
        if (self.err or self.len + total > self.buf.len) {
            self.err = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        @memset(self.buf[self.len + bytes.len ..][0 .. total - bytes.len], 0);
        self.len += total;
    }
};

pub fn fixedToF64(v: i32) f64 {
    return @as(f64, @floatFromInt(v)) / 256.0;
}

pub fn fixedFromF64(v: f64) i32 {
    return @intFromFloat(@round(v * 256.0));
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "header round-trip" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf, 7, 3);
    b.putUint(42);
    const msg = try b.finish();
    try t.expectEqual(@as(usize, 12), msg.len);

    const hdr = (try parseHeader(msg)).?;
    try t.expectEqual(@as(u32, 7), hdr.object);
    try t.expectEqual(@as(u16, 3), hdr.opcode);
    try t.expectEqual(@as(u16, 12), hdr.size);
}

test "parseHeader: short buffer buffers more, bad size rejects" {
    try t.expectEqual(@as(?Header, null), try parseHeader(&[_]u8{ 1, 2, 3 }));

    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, native_endian);
    std.mem.writeInt(u32, buf[4..8], (4 << 16) | 0, native_endian); // size 4 < header
    try t.expectError(Error.Malformed, parseHeader(&buf));
    std.mem.writeInt(u32, buf[4..8], (10 << 16) | 0, native_endian); // unaligned
    try t.expectError(Error.Malformed, parseHeader(&buf));
}

test "all scalar args round-trip" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf, 1, 0);
    b.putInt(-5);
    b.putUint(99);
    b.putFixed(fixedFromF64(1.5));
    b.putObject(12);
    b.putNewId(13);
    const msg = try b.finish();

    var it = ArgIter.init(msg[header_size..], "iufon");
    try t.expectEqual(@as(i32, -5), (try it.next()).?.int);
    try t.expectEqual(@as(u32, 99), (try it.next()).?.uint);
    try t.expectEqual(@as(f64, 1.5), fixedToF64((try it.next()).?.fixed));
    try t.expectEqual(@as(u32, 12), (try it.next()).?.object);
    try t.expectEqual(@as(u32, 13), (try it.next()).?.new_id);
    try t.expectEqual(@as(?Arg, null), try it.next());
}

test "string: padding, NUL, null string" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf, 1, 0);
    b.putString("wl_shm"); // 6 + NUL = 7 → padded to 8
    b.putString(null);
    b.putUint(0xdead);
    const msg = try b.finish();
    try t.expectEqual(@as(usize, header_size + 4 + 8 + 4 + 4), msg.len);

    var it = ArgIter.init(msg[header_size..], "s?su");
    try t.expectEqualStrings("wl_shm", (try it.next()).?.string.?);
    try t.expectEqual(@as(?[]const u8, null), (try it.next()).?.string);
    try t.expectEqual(@as(u32, 0xdead), (try it.next()).?.uint);
}

test "array round-trip with padding" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf, 1, 0);
    b.putArray(&[_]u8{ 1, 2, 3, 4, 5 }); // padded to 8
    b.putInt(7);
    const msg = try b.finish();

    var it = ArgIter.init(msg[header_size..], "ai");
    try t.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, (try it.next()).?.array);
    try t.expectEqual(@as(i32, 7), (try it.next()).?.int);
}

test "fd args consume no body bytes" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf, 1, 0);
    b.putNewId(3);
    b.putInt(4096);
    const msg = try b.finish();

    // wl_shm.create_pool(id: new_id, fd: h, size: i)
    var it = ArgIter.init(msg[header_size..], "nhi");
    try t.expectEqual(@as(u32, 3), (try it.next()).?.new_id);
    try t.expectEqual(Arg.fd, (try it.next()).?);
    try t.expectEqual(@as(i32, 4096), (try it.next()).?.int);
}

test "malformed: truncated body and missing NUL" {
    const short = [_]u8{ 1, 0, 0, 0 };
    var it = ArgIter.init(&short, "uu");
    _ = (try it.next()).?;
    try t.expectError(Error.Malformed, it.next());

    // string claims len 4 but last byte is not NUL
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 4, native_endian);
    @memcpy(buf[4..8], "abcd");
    var it2 = ArgIter.init(buf[0..8], "s");
    try t.expectError(Error.Malformed, it2.next());
}

test "builder overflow reports NoSpace" {
    var buf: [12]u8 = undefined;
    var b = Builder.init(&buf, 1, 0);
    b.putUint(1);
    b.putUint(2); // overflows
    try t.expectError(Error.NoSpace, b.finish());
}

test "fixed point conversions" {
    try t.expectEqual(@as(i32, 256), fixedFromF64(1.0));
    try t.expectEqual(@as(i32, -384), fixedFromF64(-1.5));
    try t.expectEqual(@as(f64, 0.25), fixedToF64(64));
}

//! Minimal D-Bus wire codec for the daemon's per-session a11y bus
//! (a11yhub.zig). Little-endian only (bus and app share the host).
//! Covers exactly the subset AT-SPI traffic needs: the fixed header
//! + header-fields array, and body marshaling for the types that
//! appear in org.a11y.atspi calls (y b n q i u x t d s o g v a struct).
//! No libdbus, no GLib — pure std + slices, so the mux daemon stays
//! libc-only and musl-static.

const std = @import("std");

pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
    _,
};

/// Header field codes (D-Bus spec).
pub const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,
};

pub const Message = struct {
    mtype: MessageType = .method_call,
    flags: u8 = 0,
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    /// Marshaled body bytes (alignment is relative to body start,
    /// which the spec 8-aligns — so slices compose correctly).
    body: []const u8 = "",
};

pub const Error = error{ Malformed, BigEndian, OutOfMemory };

fn alignTo(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

// ── body writer ─────────────────────────────────────────────────

/// Appends D-Bus-marshaled values; offsets are relative to the body
/// start (valid because the body itself begins 8-aligned).
pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn pad(self: *Writer, a: usize) Error!void {
        while (self.buf.items.len % a != 0)
            self.buf.append(self.allocator, 0) catch return Error.OutOfMemory;
    }

    pub fn putByte(self: *Writer, v: u8) Error!void {
        self.buf.append(self.allocator, v) catch return Error.OutOfMemory;
    }

    pub fn putU32(self: *Writer, v: u32) Error!void {
        try self.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        self.buf.appendSlice(self.allocator, &b) catch return Error.OutOfMemory;
    }

    pub fn putI32(self: *Writer, v: i32) Error!void {
        try self.putU32(@bitCast(v));
    }

    pub fn putBool(self: *Writer, v: bool) Error!void {
        try self.putU32(@intFromBool(v));
    }

    /// s and o (both: u32 length + bytes + NUL).
    pub fn putString(self: *Writer, s: []const u8) Error!void {
        try self.putU32(@intCast(s.len));
        self.buf.appendSlice(self.allocator, s) catch return Error.OutOfMemory;
        self.buf.append(self.allocator, 0) catch return Error.OutOfMemory;
    }

    /// g (signature: u8 length + bytes + NUL).
    pub fn putSig(self: *Writer, s: []const u8) Error!void {
        try self.putByte(@intCast(s.len));
        self.buf.appendSlice(self.allocator, s) catch return Error.OutOfMemory;
        self.buf.append(self.allocator, 0) catch return Error.OutOfMemory;
    }

    /// Variant holding a single string.
    pub fn putVariantString(self: *Writer, s: []const u8) Error!void {
        try self.putSig("s");
        try self.putString(s);
    }

    pub const ArrayToken = struct { len_at: usize, content_start: usize };

    /// Begin an array: length placeholder + padding to the element
    /// alignment (which the length excludes, per spec).
    pub fn beginArray(self: *Writer, elem_align: usize) Error!ArrayToken {
        try self.putU32(0);
        const len_at = self.buf.items.len - 4;
        try self.pad(elem_align);
        return .{ .len_at = len_at, .content_start = self.buf.items.len };
    }

    pub fn endArray(self: *Writer, token: ArrayToken) void {
        const len: u32 = @intCast(self.buf.items.len - token.content_start);
        std.mem.writeInt(u32, self.buf.items[token.len_at..][0..4], len, .little);
    }
};

// ── body reader ─────────────────────────────────────────────────

/// Sequential reader over marshaled body bytes. Callers drive it by
/// signature knowledge; every getter validates bounds.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    fn skipPad(self: *Reader, a: usize) Error!void {
        const p = alignTo(self.pos, a);
        if (p > self.bytes.len) return Error.Malformed;
        self.pos = p;
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return Error.Malformed;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn u32v(self: *Reader) Error!u32 {
        try self.skipPad(4);
        if (self.pos + 4 > self.bytes.len) return Error.Malformed;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn i32v(self: *Reader) Error!i32 {
        return @bitCast(try self.u32v());
    }

    pub fn u64v(self: *Reader) Error!u64 {
        try self.skipPad(8);
        if (self.pos + 8 > self.bytes.len) return Error.Malformed;
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    /// s and o.
    pub fn string(self: *Reader) Error![]const u8 {
        const len = try self.u32v();
        if (self.pos + len + 1 > self.bytes.len) return Error.Malformed;
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += len + 1;
        return s;
    }

    /// g.
    pub fn sig(self: *Reader) Error![]const u8 {
        const len = try self.byte();
        if (self.pos + len + 1 > self.bytes.len) return Error.Malformed;
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += @as(usize, len) + 1;
        return s;
    }

    /// Array: returns a sub-reader over the content. `elem_align`
    /// must match the element type's alignment.
    pub fn array(self: *Reader, elem_align: usize) Error!Reader {
        const len = try self.u32v();
        try self.skipPad(elem_align);
        if (self.pos + len > self.bytes.len) return Error.Malformed;
        // Content alignment stays message-relative: keep absolute
        // positions by slicing the ORIGINAL buffer.
        var sub = Reader{ .bytes = self.bytes[0 .. self.pos + len], .pos = self.pos };
        self.pos += len;
        _ = &sub;
        return sub;
    }

    pub fn atEnd(self: *Reader) bool {
        return self.pos >= self.bytes.len;
    }

    pub fn structStart(self: *Reader) Error!void {
        try self.skipPad(8);
    }

    /// Skip one complete value of signature `s` (subset used by
    /// AT-SPI replies). Returns unconsumed remainder of `s`.
    pub fn skipValue(self: *Reader, s: []const u8) Error![]const u8 {
        if (s.len == 0) return Error.Malformed;
        switch (s[0]) {
            'y' => {
                _ = try self.byte();
                return s[1..];
            },
            'b', 'u', 'i' => {
                _ = try self.u32v();
                return s[1..];
            },
            'n', 'q' => {
                try self.skipPad(2);
                if (self.pos + 2 > self.bytes.len) return Error.Malformed;
                self.pos += 2;
                return s[1..];
            },
            'x', 't', 'd' => {
                _ = try self.u64v();
                return s[1..];
            },
            's', 'o' => {
                _ = try self.string();
                return s[1..];
            },
            'g' => {
                _ = try self.sig();
                return s[1..];
            },
            'v' => {
                const vs = try self.sig();
                var rest = vs;
                while (rest.len > 0) rest = try self.skipValue(rest);
                return s[1..];
            },
            'a' => {
                const elem = s[1..];
                if (elem.len == 0) return Error.Malformed;
                var sub = try self.array(sigAlign(elem));
                while (!sub.atEnd()) _ = try sub.skipValue(elem);
                return sigSkipOne(elem);
            },
            '(' => {
                try self.structStart();
                var rest = s[1..];
                while (rest.len > 0 and rest[0] != ')') rest = try self.skipValue(rest);
                if (rest.len == 0) return Error.Malformed;
                return rest[1..];
            },
            '{' => {
                try self.structStart();
                var rest = s[1..];
                while (rest.len > 0 and rest[0] != '}') rest = try self.skipValue(rest);
                if (rest.len == 0) return Error.Malformed;
                return rest[1..];
            },
            else => return Error.Malformed,
        }
    }
};

/// Natural alignment of the FIRST complete type in `s`.
pub fn sigAlign(s: []const u8) usize {
    if (s.len == 0) return 1;
    return switch (s[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'u', 'i', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Skip one complete type in a signature string (not the data).
pub fn sigSkipOne(s: []const u8) Error![]const u8 {
    if (s.len == 0) return Error.Malformed;
    switch (s[0]) {
        'a' => return sigSkipOne(s[1..]),
        '(' => {
            var rest = s[1..];
            var depth: usize = 1;
            while (rest.len > 0) {
                if (rest[0] == '(') depth += 1;
                if (rest[0] == ')') {
                    depth -= 1;
                    if (depth == 0) return rest[1..];
                }
                rest = rest[1..];
            }
            return Error.Malformed;
        },
        '{' => {
            var rest = s[1..];
            var depth: usize = 1;
            while (rest.len > 0) {
                if (rest[0] == '{') depth += 1;
                if (rest[0] == '}') {
                    depth -= 1;
                    if (depth == 0) return rest[1..];
                }
                rest = rest[1..];
            }
            return Error.Malformed;
        },
        else => return s[1..],
    }
}

// ── message marshal / unmarshal ─────────────────────────────────

/// Serialize a message (little-endian). Caller owns the bytes.
pub fn marshal(allocator: std.mem.Allocator, msg: Message) Error![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();

    try w.putByte('l');
    try w.putByte(@intFromEnum(msg.mtype));
    try w.putByte(msg.flags);
    try w.putByte(1); // protocol version
    try w.putU32(@intCast(msg.body.len));
    try w.putU32(msg.serial);

    // Header fields: ARRAY of STRUCT(yv); array length excludes the
    // padding that 8-aligns the body afterwards.
    const len_at = w.buf.items.len;
    try w.putU32(0); // patched below
    const fields_start = w.buf.items.len;

    const putField = struct {
        fn str(wr: *Writer, code: u8, vsig: []const u8, val: []const u8) Error!void {
            try wr.pad(8);
            try wr.putByte(code);
            try wr.putSig(vsig);
            try wr.putString(val);
        }
        fn num(wr: *Writer, code: u8, val: u32) Error!void {
            try wr.pad(8);
            try wr.putByte(code);
            try wr.putSig("u");
            try wr.putU32(val);
        }
        fn sg(wr: *Writer, code: u8, val: []const u8) Error!void {
            try wr.pad(8);
            try wr.putByte(code);
            try wr.putSig("g");
            try wr.putSig(val);
        }
    };

    if (msg.path) |v| try putField.str(&w, @intFromEnum(Field.path), "o", v);
    if (msg.interface) |v| try putField.str(&w, @intFromEnum(Field.interface), "s", v);
    if (msg.member) |v| try putField.str(&w, @intFromEnum(Field.member), "s", v);
    if (msg.error_name) |v| try putField.str(&w, @intFromEnum(Field.error_name), "s", v);
    if (msg.reply_serial) |v| try putField.num(&w, @intFromEnum(Field.reply_serial), v);
    if (msg.destination) |v| try putField.str(&w, @intFromEnum(Field.destination), "s", v);
    if (msg.sender) |v| try putField.str(&w, @intFromEnum(Field.sender), "s", v);
    if (msg.signature) |v| try putField.sg(&w, @intFromEnum(Field.signature), v);

    const fields_len: u32 = @intCast(w.buf.items.len - fields_start);
    std.mem.writeInt(u32, w.buf.items[len_at..][0..4], fields_len, .little);

    try w.pad(8); // body starts 8-aligned
    w.buf.appendSlice(allocator, msg.body) catch return Error.OutOfMemory;
    return w.buf.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

pub const Unmarshaled = struct {
    msg: Message,
    /// Total bytes this message consumed from the stream.
    consumed: usize,
};

/// Peel one message off `bytes`. Null = incomplete. Field slices
/// point INTO `bytes` — copy before the buffer moves.
pub fn unmarshal(bytes: []const u8) Error!?Unmarshaled {
    if (bytes.len < 16) return null;
    if (bytes[0] == 'B') return Error.BigEndian;
    if (bytes[0] != 'l') return Error.Malformed;
    const body_len = std.mem.readInt(u32, bytes[4..8], .little);
    const fields_len = std.mem.readInt(u32, bytes[12..16], .little);
    const body_start = alignTo(16 + @as(usize, fields_len), 8);
    const total = body_start + body_len;
    if (total > 128 * 1024 * 1024) return Error.Malformed;
    if (bytes.len < total) return null;

    var msg = Message{
        .mtype = @enumFromInt(bytes[1]),
        .flags = bytes[2],
        .serial = std.mem.readInt(u32, bytes[8..12], .little),
        .body = bytes[body_start..total],
    };

    var r = Reader{ .bytes = bytes[0 .. 16 + fields_len], .pos = 16 };
    while (!r.atEnd()) {
        r.structStart() catch break;
        if (r.atEnd()) break;
        const code = try r.byte();
        const vsig = try r.sig();
        switch (code) {
            1 => msg.path = try r.string(),
            2 => msg.interface = try r.string(),
            3 => msg.member = try r.string(),
            4 => msg.error_name = try r.string(),
            5 => msg.reply_serial = try r.u32v(),
            6 => msg.destination = try r.string(),
            7 => msg.sender = try r.string(),
            8 => msg.signature = try r.sig(),
            else => {
                var rest = vsig;
                while (rest.len > 0) rest = try r.skipValue(rest);
            },
        }
    }
    return .{ .msg = msg, .consumed = total };
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "method call round-trips through marshal/unmarshal" {
    const a = t.allocator;
    var bw = Writer.init(a);
    defer bw.deinit();
    try bw.putString("org.a11y.atspi.Accessible");
    try bw.putString("Name");

    const bytes = try marshal(a, .{
        .mtype = .method_call,
        .serial = 7,
        .path = "/org/a11y/atspi/accessible/root",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = ":1.0",
        .sender = ":0",
        .signature = "ss",
        .body = bw.buf.items,
    });
    defer a.free(bytes);

    const got = (try unmarshal(bytes)).?;
    try t.expectEqual(bytes.len, got.consumed);
    try t.expectEqual(MessageType.method_call, got.msg.mtype);
    try t.expectEqual(@as(u32, 7), got.msg.serial);
    try t.expectEqualStrings("/org/a11y/atspi/accessible/root", got.msg.path.?);
    try t.expectEqualStrings("Get", got.msg.member.?);
    try t.expectEqualStrings("ss", got.msg.signature.?);

    var r = Reader.init(got.msg.body);
    try t.expectEqualStrings("org.a11y.atspi.Accessible", try r.string());
    try t.expectEqualStrings("Name", try r.string());
    try t.expect(r.atEnd());
}

test "incomplete stream returns null, split at every point" {
    const a = t.allocator;
    const bytes = try marshal(a, .{ .mtype = .method_return, .serial = 1, .reply_serial = 9 });
    defer a.free(bytes);
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        try t.expectEqual(@as(?Unmarshaled, null), try unmarshal(bytes[0..cut]));
    }
    const got = (try unmarshal(bytes)).?;
    try t.expectEqual(@as(u32, 9), got.msg.reply_serial.?);
}

test "reader walks arrays of structs (so) with absolute alignment" {
    const a = t.allocator;
    var bw = Writer.init(a);
    defer bw.deinit();
    // a(so) with two entries, as GetChildren returns.
    const tok = blk: {
        try bw.putU32(0);
        const at = bw.buf.items.len - 4;
        try bw.pad(8);
        break :blk at;
    };
    const content_start = bw.buf.items.len;
    try bw.pad(8);
    try bw.putString(":1.5");
    try bw.putString("/org/a11y/atspi/accessible/1");
    try bw.pad(8);
    try bw.putString(":1.5");
    try bw.putString("/org/a11y/atspi/accessible/2");
    std.mem.writeInt(u32, bw.buf.items[tok..][0..4], @intCast(bw.buf.items.len - content_start), .little);

    var r = Reader.init(bw.buf.items);
    var sub = try r.array(8);
    var n: usize = 0;
    while (!sub.atEnd()) : (n += 1) {
        try sub.structStart();
        _ = try sub.string();
        const path = try sub.string();
        try t.expect(std.mem.startsWith(u8, path, "/org/a11y/atspi/accessible/"));
    }
    try t.expectEqual(@as(usize, 2), n);
}

test "skipValue handles variants and nested arrays" {
    const a = t.allocator;
    var bw = Writer.init(a);
    defer bw.deinit();
    // v containing au (as GetState's wrapped form would).
    try bw.putSig("au");
    const tok = blk: {
        try bw.putU32(0);
        const at = bw.buf.items.len - 4;
        try bw.pad(4);
        break :blk at;
    };
    const cs = bw.buf.items.len;
    try bw.putU32(123);
    try bw.putU32(456);
    std.mem.writeInt(u32, bw.buf.items[tok..][0..4], @intCast(bw.buf.items.len - cs), .little);
    try bw.putString("after");

    var r = Reader.init(bw.buf.items);
    _ = try r.skipValue("v");
    try t.expectEqualStrings("after", try r.string());
}

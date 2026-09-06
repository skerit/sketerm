//! Kitty graphics protocol parser (APC G=…).
//!
//! Wire format: `APC G key=value,key=value,…[;<base64 payload>] ST`
//!
//! v1 detects the command and exposes payload + key params; full
//! placement / image-store integration is post-checkpoint.

const std = @import("std");

pub const Action = enum {
    transmit,
    transmit_and_place,
    place,
    delete,
    query,
    /// `a=f` — append/compose a frame to an existing animation.
    transmit_frame,
    /// `a=a` — animation control (play/pause/loop count).
    animate,
    unknown,
};

/// True for the transmission media that name a PATH instead of
/// carrying pixels: `t=f` file, `t=t` tempfile, `t=s` POSIX shm.
///
/// The one declaring home for that set. Everything that decides
/// "this APC resolves against whatever host applies it" (the daemon's
/// inline-or-drop gate, the client-side refusal, the file reader)
/// consumes this rather than spelling the letters again; the client
/// reader once listed only two of the three.
pub fn isFileMedium(medium: u8) bool {
    return switch (medium) {
        'f', 't', 's' => true,
        else => false,
    };
}

/// The spec's safety rule for `t=t`: a terminal deletes the tempfile
/// after reading it ONLY when its path contains this marker, so a
/// client cannot aim the terminal's unlink at an arbitrary file.
pub const TEMPFILE_MARKER = "tty-graphics-protocol";

/// @return whether a `t=t` path may be unlinked after reading.
pub fn tempfileDeletable(path: []const u8) bool {
    return std.mem.indexOf(u8, path, TEMPFILE_MARKER) != null;
}

/// The path a `t=s` transmission names, as the daemon or client opens
/// it: POSIX shm objects live under /dev/shm on Linux.
pub fn shmPath(buf: []u8, name: []const u8) ?[]const u8 {
    const bare = std.mem.trimStart(u8, name, "/");
    return std.fmt.bufPrint(buf, "/dev/shm/{s}", .{bare}) catch null;
}

pub const Command = struct {
    action: Action = .unknown,
    /// Image id (`i=`).
    image_id: u32 = 0,
    /// Placement id (`p=`).
    placement_id: u32 = 0,
    /// Format (`f=`): 24=RGB, 32=RGBA, 100=PNG.
    format: u32 = 0,
    /// Width / height in pixels (`s=` / `v=`).
    width: u32 = 0,
    height: u32 = 0,
    /// Z-order (`z=`).
    z: i32 = 0,
    /// Compression (`o=`): 0=none, 1=zlib, maxInt(u32)=unsupported.
    compression: u32 = 0,
    /// Quiet level (`q=`): 0=verbose, 1/2=quiet error response.
    quiet: u32 = 0,
    /// More-chunks-follow (`m=`): 1=yes.
    more: u32 = 0,
    /// Transmission medium (`t=`): d=direct, t=tempfile, s=shmem, f=file.
    medium: u8 = 'd',
    /// Delete subcommand (`d=`): A=all, I=intersect cursor, N=image_number,
    /// R=z-range, P=placement, plus lowercase variants that don't free
    /// data. Default 'a' (all visible). Only inspected when action=delete.
    delete_what: u8 = 'a',
    /// Source rect in image-pixel coords (`x=`,`y=`,`w=`,`h=`). For
    /// placements: which sub-region of the image to render. Defaults
    /// to the whole image when w/h are 0.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// Destination size in cells (`c=`,`r=`). When >0 the image is
    /// scaled to fit exactly this many cells; otherwise it renders at
    /// native pixel size (1 image-pixel per terminal-pixel).
    cells_wide: u32 = 0,
    cells_high: u32 = 0,
    /// `C=1`: don't move the cursor after placement (the app draws on
    /// top of the image without scrolling).
    no_cursor_move: u8 = 0,
    /// `U=1`: this is a Unicode-placeholder (virtual) placement — the
    /// image is positioned later by U+10EEEE cells, not at the cursor.
    unicode_placement: u8 = 0,
    /// Image NUMBER (`I=`) — a client-chosen tag the terminal maps to
    /// an id it assigns itself. Distinct from `image_id`; `d=n/N`
    /// deletes by it.
    image_number: u32 = 0,
    /// `S=` size in bytes and `O=` offset, for the file and shared
    /// memory transfer media.
    data_size: u32 = 0,
    data_offset: u32 = 0,
    /// Pixel offset within the starting cell (`X=`, `Y=`), so an image
    /// can be positioned off the cell grid. For `a=f` these two mean
    /// the frame composition mode and background colour instead.
    cell_x_offset: u32 = 0,
    cell_y_offset: u32 = 0,
    /// Relative placement (`P=` parent image, `Q=` parent placement)
    /// with its offset in cells (`H=`, `V=`).
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_dx: i32 = 0,
    parent_dy: i32 = 0,
    /// `N=1`: the client says this image is transient and need not be
    /// kept once its placements are gone.
    transient: u8 = 0,
    /// Raw payload after the ';'. May be empty.
    payload: []const u8 = &.{},
};

pub const Error = error{InvalidFormat};

pub fn parse(body: []const u8) Error!Command {
    if (body.len == 0) return Error.InvalidFormat;
    if (body[0] != 'G') return Error.InvalidFormat;

    var cmd = Command{};
    var i: usize = 1;

    // The control section ends at the first ';'. Every scan below is
    // bounded by it: base64 payloads carry '=' padding, and searching
    // past the separator for the next key's '=' used to land `i` beyond
    // the payload marker, silently dropping the whole transmission.
    const ctrl_end = std.mem.indexOfScalarPos(u8, body, 1, ';') orelse body.len;
    const ctrl = body[0..ctrl_end];

    // Parse key=value pairs separated by commas.
    while (i < ctrl.len) {
        // Skip leading commas.
        if (ctrl[i] == ',') {
            i += 1;
            continue;
        }
        const eq = std.mem.indexOfScalarPos(u8, ctrl, i, '=') orelse break;
        const next_sep = std.mem.indexOfScalarPos(u8, ctrl, eq + 1, ',') orelse ctrl.len;
        const key = ctrl[i..eq];
        const val = ctrl[eq + 1 .. next_sep];
        applyKv(&cmd, key, val);
        i = next_sep;
    }

    if (ctrl_end < body.len) {
        cmd.payload = body[ctrl_end + 1 ..];
    }
    return cmd;
}

fn applyKv(cmd: *Command, key: []const u8, val: []const u8) void {
    if (key.len != 1) return;
    const k = key[0];
    switch (k) {
        'a' => {
            if (val.len > 0) cmd.action = switch (val[0]) {
                't' => .transmit,
                'T' => .transmit_and_place,
                'p' => .place,
                'd' => .delete,
                'q' => .query,
                'f' => .transmit_frame,
                'a' => .animate,
                else => .unknown,
            };
        },
        'i' => cmd.image_id = parseUint(val),
        'p' => cmd.placement_id = parseUint(val),
        'f' => cmd.format = parseUint(val),
        's' => cmd.width = parseUint(val),
        'v' => cmd.height = parseUint(val),
        'z' => cmd.z = parseInt(val),
        'o' => cmd.compression = parseCompression(val),
        'q' => cmd.quiet = parseUint(val),
        'm' => cmd.more = parseUint(val),
        'x' => cmd.src_x = parseUint(val),
        'y' => cmd.src_y = parseUint(val),
        'w' => cmd.src_w = parseUint(val),
        'h' => cmd.src_h = parseUint(val),
        'c' => cmd.cells_wide = parseUint(val),
        'r' => cmd.cells_high = parseUint(val),
        'C' => if (val.len > 0) {
            cmd.no_cursor_move = val[0];
        },
        'U' => if (val.len > 0) {
            cmd.unicode_placement = val[0] -% '0';
        },
        't' => if (val.len > 0) {
            cmd.medium = val[0];
        },
        'd' => if (val.len > 0) {
            cmd.delete_what = val[0];
        },
        'I' => cmd.image_number = parseUint(val),
        'S' => cmd.data_size = parseUint(val),
        'O' => cmd.data_offset = parseUint(val),
        'X' => cmd.cell_x_offset = parseUint(val),
        'Y' => cmd.cell_y_offset = parseUint(val),
        'P' => cmd.parent_image_id = parseUint(val),
        'Q' => cmd.parent_placement_id = parseUint(val),
        'H' => cmd.parent_dx = parseInt(val),
        'V' => cmd.parent_dy = parseInt(val),
        'N' => cmd.transient = if (val.len > 0) val[0] -% '0' else 0,
        else => {},
    }
}

fn parseUint(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |b| {
        if (b >= '0' and b <= '9') n = n *| 10 +| (b - '0') else break;
    }
    return n;
}

fn parseCompression(s: []const u8) u32 {
    if (std.mem.eql(u8, s, "z") or std.mem.eql(u8, s, "1")) return 1;
    if (std.mem.eql(u8, s, "0")) return 0;
    return std.math.maxInt(u32);
}

fn parseInt(s: []const u8) i32 {
    if (s.len == 0) return 0;
    if (s[0] == '-') {
        const mag = @min(parseUint(s[1..]), @as(u32, std.math.maxInt(i32)) + 1);
        if (mag == @as(u32, std.math.maxInt(i32)) + 1) return std.math.minInt(i32);
        return -@as(i32, @intCast(mag));
    }
    return @intCast(@min(parseUint(s), std.math.maxInt(i32)));
}

test "transmit and place RGBA" {
    // a=T,f=32,s=10,v=20,i=1;<payload>
    const cmd = try parse("Ga=T,f=32,s=10,v=20,i=1;ABCD");
    try std.testing.expectEqual(Action.transmit_and_place, cmd.action);
    try std.testing.expectEqual(@as(u32, 32), cmd.format);
    try std.testing.expectEqual(@as(u32, 10), cmd.width);
    try std.testing.expectEqual(@as(u32, 20), cmd.height);
    try std.testing.expectEqual(@as(u32, 1), cmd.image_id);
    try std.testing.expectEqualStrings("ABCD", cmd.payload);
}

test "delete by image id" {
    const cmd = try parse("Ga=d,i=42");
    try std.testing.expectEqual(Action.delete, cmd.action);
    try std.testing.expectEqual(@as(u32, 42), cmd.image_id);
    try std.testing.expectEqualStrings("", cmd.payload);
}

test "negative z" {
    const cmd = try parse("Ga=p,i=1,z=-3");
    try std.testing.expectEqual(@as(i32, -3), cmd.z);
}

test "oversized numeric fields saturate instead of overflowing" {
    const cmd = try parse("Ga=p,i=99999999999999999999,z=3000000000");
    try std.testing.expectEqual(std.math.maxInt(u32), cmd.image_id);
    try std.testing.expectEqual(std.math.maxInt(i32), cmd.z);
    const neg = try parse("Ga=p,z=-99999999999999999999");
    try std.testing.expectEqual(std.math.minInt(i32), neg.z);
}

test "compression accepts zlib literals and rejects unknown codecs" {
    const zlib = try parse("Ga=t,o=z");
    try std.testing.expectEqual(@as(u32, 1), zlib.compression);
    const numeric = try parse("Ga=t,o=1");
    try std.testing.expectEqual(@as(u32, 1), numeric.compression);
    const unknown = try parse("Ga=t,o=x");
    try std.testing.expectEqual(std.math.maxInt(u32), unknown.compression);
}

test "unicode placement flag + grid size" {
    const cmd = try parse("Ga=T,U=1,i=3,c=4,r=2");
    try std.testing.expectEqual(@as(u8, 1), cmd.unicode_placement);
    try std.testing.expectEqual(@as(u32, 4), cmd.cells_wide); // c=
    try std.testing.expectEqual(@as(u32, 2), cmd.cells_high); // r=
}

test "isFileMedium is the one home for the path-naming media" {
    const t = std.testing;
    // Every letter the parser can produce, classified against the
    // three the protocol defines as path-naming.
    var m: u16 = 0;
    while (m < 256) : (m += 1) {
        const medium: u8 = @intCast(m);
        const expect = medium == 'f' or medium == 't' or medium == 's';
        try t.expectEqual(expect, isFileMedium(medium));
    }
    // The parsed command's default medium is direct, never a file.
    const cmd = try parse("Ga=T,f=100;QUJD");
    try t.expect(!isFileMedium(cmd.medium));
    try t.expect(isFileMedium((try parse("Ga=T,t=s;QUJD")).medium));
}

test "a control key without '=' does not swallow the payload" {
    // The '=' search used to run past the ';' into the base64 body, so
    // the whole transmission was silently dropped.
    const cmd = try parse("Ga=T,f=100,q;QUJD");
    try std.testing.expectEqualStrings("QUJD", cmd.payload);
    try std.testing.expectEqual(Action.transmit_and_place, cmd.action);
    try std.testing.expectEqual(@as(u32, 100), cmd.format);
    // Base64 padding is an '=' too, and must not be read as a key.
    const padded = try parse("Ga=T,q;QQ==");
    try std.testing.expectEqualStrings("QQ==", padded.payload);
}

test "tempfileDeletable follows the spec's marker rule" {
    const t = std.testing;
    try t.expect(tempfileDeletable("/tmp/tty-graphics-protocol-abc"));
    try t.expect(tempfileDeletable("/dev/shm/x/tty-graphics-protocol"));
    try t.expect(!tempfileDeletable("/home/me/.ssh/id_rsa"));
    try t.expect(!tempfileDeletable(""));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/dev/shm/obj", shmPath(&buf, "/obj").?);
    try t.expectEqualStrings("/dev/shm/obj", shmPath(&buf, "obj").?);
    var tiny: [4]u8 = undefined;
    try t.expect(shmPath(&tiny, "obj") == null);
}

//! Kitty graphics protocol parser (APC G=…).
//!
//! Wire format: `APC G key=value,key=value,…[;<base64 payload>] ST`
//!
//! v1 detects the command and exposes payload + key params; full
//! placement / image-store integration is post-checkpoint.

const std = @import("std");

pub const Action = enum { transmit, transmit_and_place, place, delete, query, unknown };

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
    /// Compression (`o=`): 0=none, 1=zlib.
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
    /// Raw payload after the ';'. May be empty.
    payload: []const u8 = &.{},
};

pub const Error = error{ InvalidFormat };

pub fn parse(body: []const u8) Error!Command {
    if (body.len == 0) return Error.InvalidFormat;
    if (body[0] != 'G') return Error.InvalidFormat;

    var cmd = Command{};
    var i: usize = 1;

    // Parse key=value pairs separated by commas, until we hit ';' or end.
    while (i < body.len and body[i] != ';') {
        // Skip leading commas.
        if (body[i] == ',') {
            i += 1;
            continue;
        }
        const eq = std.mem.indexOfScalarPos(u8, body, i, '=') orelse break;
        const next_sep = blk: {
            var j: usize = eq + 1;
            while (j < body.len) : (j += 1) {
                if (body[j] == ',' or body[j] == ';') break;
            }
            break :blk j;
        };
        const key = body[i..eq];
        const val = body[eq + 1 .. next_sep];
        applyKv(&cmd, key, val);
        i = next_sep;
    }

    if (i < body.len and body[i] == ';') {
        cmd.payload = body[i + 1 ..];
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
                else => .unknown,
            };
        },
        'i' => cmd.image_id = parseUint(val),
        'p' => cmd.placement_id = parseUint(val),
        'f' => cmd.format = parseUint(val),
        's' => cmd.width = parseUint(val),
        'v' => cmd.height = parseUint(val),
        'z' => cmd.z = parseInt(val),
        'o' => cmd.compression = parseUint(val),
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
        't' => if (val.len > 0) {
            cmd.medium = val[0];
        },
        'd' => if (val.len > 0) {
            cmd.delete_what = val[0];
        },
        else => {},
    }
}

fn parseUint(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |b| {
        if (b >= '0' and b <= '9') n = n * 10 + (b - '0') else break;
    }
    return n;
}

fn parseInt(s: []const u8) i32 {
    if (s.len == 0) return 0;
    if (s[0] == '-') {
        return -@as(i32, @intCast(parseUint(s[1..])));
    }
    return @intCast(parseUint(s));
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

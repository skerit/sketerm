//! Cell-border protocol, version 1 (draft): the one home of its vocabulary.
//!
//! `DCS 1 + b cell-border;OP;... ST` gives cells thin lines on their edges
//! and centrelines without spending character positions. This file names
//! the twelve segments and their bits, the named masks, each segment's
//! line shape (which the renderer turns into pixels), the shared-edge
//! pairs, the stroke encoding, and the atomic payload parser. Everything
//! else (Screen, the style pool, snapshots, the border renderer) derives
//! from these declarations instead of repeating a bit or a mask.
//!
//! Only the mandatory baseline is implemented: joints, `style`,
//! `priority`, `outside` and `radius` are not, so joint operations are
//! unknown ops (ignored whole) and extension keys are syntax-checked and
//! then ignored. The capability reply advertises exactly that.

const std = @import("std");

/// The DCS parameter that selects this protocol version.
pub const protocol_version = 1;

/// The reply to `q`: version 1 with the five mandatory features.
pub const query_reply = "\x1bP1+bcell-border;ok;1;pen,rect,half,center,palette\x1b\\";

/// Payloads past this many bytes are ignored whole.
pub const max_payload_len = 256;

/// Twelve segments: two halves of each outer edge, then the four centre
/// arms. The tag value IS the protocol bit number.
pub const Segment = enum(u4) {
    top_left = 0,
    top_right = 1,
    right_top = 2,
    right_bottom = 3,
    bottom_left = 4,
    bottom_right = 5,
    left_top = 6,
    left_bottom = 7,
    h_left = 8,
    h_right = 9,
    v_top = 10,
    v_bottom = 11,

    pub fn mask(self: Segment) Mask {
        return @as(Mask, 1) << @intFromEnum(self);
    }

    /// Where the segment lies in its cell; the renderer's only input.
    pub fn line(self: Segment) Line {
        return switch (self) {
            .top_left => .{ .axis = .horizontal, .at = .start, .from = .start, .to = .middle },
            .top_right => .{ .axis = .horizontal, .at = .start, .from = .middle, .to = .end },
            .right_top => .{ .axis = .vertical, .at = .end, .from = .start, .to = .middle },
            .right_bottom => .{ .axis = .vertical, .at = .end, .from = .middle, .to = .end },
            .bottom_left => .{ .axis = .horizontal, .at = .end, .from = .start, .to = .middle },
            .bottom_right => .{ .axis = .horizontal, .at = .end, .from = .middle, .to = .end },
            .left_top => .{ .axis = .vertical, .at = .start, .from = .start, .to = .middle },
            .left_bottom => .{ .axis = .vertical, .at = .start, .from = .middle, .to = .end },
            .h_left => .{ .axis = .horizontal, .at = .middle, .from = .start, .to = .middle },
            .h_right => .{ .axis = .horizontal, .at = .middle, .from = .middle, .to = .end },
            .v_top => .{ .axis = .vertical, .at = .middle, .from = .start, .to = .middle },
            .v_bottom => .{ .axis = .vertical, .at = .middle, .from = .middle, .to = .end },
        };
    }
};

pub const segments = std.enums.values(Segment);
pub const segment_count = segments.len;
pub const Mask = u12;

comptime {
    if (@bitSizeOf(Mask) != segment_count) @compileError("Mask must have one bit per segment");
}

/// A position across one cell axis.
pub const Anchor = enum { start, middle, end };

pub const Axis = enum { horizontal, vertical };

/// A segment's shape: a line along `axis`, placed at `at` across the
/// other axis and spanning `from` to `to` along its own. Only lines with
/// `at` on an outer edge honour `Placement`; centre arms are centred.
pub const Line = struct {
    axis: Axis,
    at: Anchor,
    from: Anchor,
    to: Anchor,

    pub fn onEdge(self: Line) bool {
        return self.at != .middle;
    }
};

fn maskOf(comptime list: []const Segment) Mask {
    var m: Mask = 0;
    for (list) |s| m |= s.mask();
    return m;
}

/// The named masks of the protocol's segment table.
pub const group = struct {
    pub const top = maskOf(&.{ .top_left, .top_right });
    pub const right = maskOf(&.{ .right_top, .right_bottom });
    pub const bottom = maskOf(&.{ .bottom_left, .bottom_right });
    pub const left = maskOf(&.{ .left_top, .left_bottom });
    pub const outline = top | right | bottom | left;
    pub const horizontal = maskOf(&.{ .h_left, .h_right });
    pub const vertical = maskOf(&.{ .v_top, .v_bottom });
    pub const all = outline | horizontal | vertical;
};

/// The neighbour cell a shared edge is shared with.
pub const Toward = enum { right, below };

/// Two half-segments that are the same line: `first` belongs to the left
/// or upper cell, `second` to the cell `toward` of it.
pub const SharedEdge = struct { first: Segment, second: Segment, toward: Toward };

pub const shared_edges = [_]SharedEdge{
    .{ .first = .right_top, .second = .left_top, .toward = .right },
    .{ .first = .right_bottom, .second = .left_bottom, .toward = .right },
    .{ .first = .bottom_left, .second = .top_left, .toward = .below },
    .{ .first = .bottom_right, .second = .top_right, .toward = .below },
};

/// A segment's partner across a shared edge, seen from its own cell.
pub const Partner = struct {
    segment: Segment,
    /// Neighbour offset from the segment's own cell.
    dcol: i2,
    drow: i2,
    /// True when the segment's own cell is the right or lower one,
    /// which wins a tie.
    own_is_later: bool,
};

pub fn partner(seg: Segment) ?Partner {
    for (shared_edges) |e| {
        const dcol: i2 = if (e.toward == .right) 1 else 0;
        const drow: i2 = if (e.toward == .below) 1 else 0;
        if (e.first == seg) return .{ .segment = e.second, .dcol = dcol, .drow = drow, .own_is_later = false };
        if (e.second == seg) return .{ .segment = e.first, .dcol = -dcol, .drow = -drow, .own_is_later = true };
    }
    return null;
}

pub const Placement = enum(u1) { inside = 0, centred = 1 };
pub const Layer = enum(u1) { below_text = 0, above_text = 1 };

/// A stroke colour; palette and `fg` resolve at draw time.
pub const Color = packed struct(u26) {
    value: u24 = 0,
    kind: Kind = .fg,

    pub const Kind = enum(u2) { fg = 0, palette = 1, rgb = 2, _ };
};

/// One segment's style. `width == 0` is the absent stroke, and the
/// all-zero value is the only absent encoding (`valid` enforces it), so
/// a `Set` compares and hashes by its bytes. The bit layout is carried
/// verbatim by snapshots: append fields into `_pad`, never move one.
pub const Stroke = packed struct(u64) {
    /// Total thickness in 1/256 of the cell width, 1..64.
    width: u7 = 0,
    placement: Placement = .inside,
    layer: Layer = .below_text,
    color: Color = .{},
    _pad: u29 = 0,

    pub const absent: Stroke = .{};
    pub const max_width = 64;

    pub fn present(self: Stroke) bool {
        return self.width != 0;
    }

    pub fn bits(self: Stroke) u64 {
        return @bitCast(self);
    }

    /// Whether untrusted bits (a snapshot) decode to a stroke the
    /// parser could have produced.
    pub fn valid(self: Stroke) bool {
        if (self.width == 0) return self.bits() == 0;
        if (self.width > max_width or self._pad != 0) return false;
        return switch (self.color.kind) {
            .fg => self.color.value == 0,
            .palette => self.color.value <= 255,
            .rgb => true,
            _ => false,
        };
    }
};

/// A cell's border set. Joints, outside colour and radius are not part
/// of the version 1 baseline implemented here.
pub const Set = [segment_count]Stroke;

pub const empty: Set = @splat(Stroke.absent);

pub fn isEmpty(set: Set) bool {
    for (set) |s| if (s.present()) return false;
    return true;
}

/// Mask of the segments `set` has a stroke on.
pub fn presentMask(set: Set) Mask {
    var m: Mask = 0;
    for (segments) |seg| {
        if (set[@intFromEnum(seg)].present()) m |= seg.mask();
    }
    return m;
}

/// `set` with the `mask` segments given `stroke` (absent clears them).
pub fn withStroke(set: Set, mask: Mask, stroke: Stroke) Set {
    var out = set;
    for (segments) |seg| {
        if (mask & seg.mask() != 0) out[@intFromEnum(seg)] = stroke;
    }
    return out;
}

/// Whether `own` is drawn on a shared edge whose other half is
/// `neighbour`: only two centred strokes merge, the wider wins, and a
/// tie goes to the right or lower cell.
pub fn keepsSharedEdge(own: Stroke, neighbour: Stroke, own_is_later: bool) bool {
    if (!own.present()) return false;
    if (!neighbour.present() or own.placement != .centred or neighbour.placement != .centred) return true;
    if (own.width != neighbour.width) return own.width > neighbour.width;
    return own_is_later;
}

/// Operations, named exactly as they appear on the wire. The joint
/// operations are not baseline and stay unknown, so a payload using them
/// is ignored whole.
pub const Op = enum {
    q,
    pen,
    @"pen-clear",
    set,
    clear,

    fn takesMask(self: Op) bool {
        return self != .q;
    }

    /// Only stroke commands accept extension fields.
    fn takesStroke(self: Op) bool {
        return self == .pen or self == .set;
    }

    fn takesRect(self: Op) bool {
        return self == .set or self == .clear;
    }
};

/// One validated command. `stroke` is absent for the clearing ops.
pub const Command = struct {
    op: Op,
    mask: Mask = 0,
    stroke: Stroke = .absent,
    rows: u16 = 1,
    cols: u16 = 1,

    pub fn apply(self: Command, set: Set) Set {
        return withStroke(set, self.mask, self.stroke);
    }
};

/// Parse a payload, or null when it is malformed in any way: a terminal
/// never applies part of a command.
pub fn parse(body: []const u8) ?Command {
    if (body.len > max_payload_len) return null;
    var fields = std.mem.splitScalar(u8, body, ';');
    if (!std.mem.eql(u8, fields.next() orelse return null, "cell-border")) return null;
    const op = std.meta.stringToEnum(Op, fields.next() orelse return null) orelse return null;
    var cmd: Command = .{ .op = op };
    if (op.takesMask()) {
        cmd.mask = @intCast(decimal(fields.next(), 1, group.all) orelse return null);
    }
    if (op.takesStroke()) {
        const width = decimal(fields.next(), 1, Stroke.max_width) orelse return null;
        const color = parseColor(fields.next() orelse return null) orelse return null;
        const placement = decimal(fields.next(), 0, 1) orelse return null;
        const layer = decimal(fields.next(), 0, 1) orelse return null;
        cmd.stroke = .{
            .width = @intCast(width),
            .placement = @enumFromInt(placement),
            .layer = @enumFromInt(layer),
            .color = color,
        };
    }
    if (op.takesRect()) {
        cmd.rows = @intCast(decimal(fields.next(), 1, std.math.maxInt(u16)) orelse return null);
        cmd.cols = @intCast(decimal(fields.next(), 1, std.math.maxInt(u16)) orelse return null);
    }
    while (fields.next()) |field| {
        if (!op.takesStroke() or !isExtensionField(field)) return null;
    }
    return cmd;
}

/// Unsigned decimal in `min..max`; leading zeros allowed, no sign.
fn decimal(field: ?[]const u8, min: u32, max: u32) ?u32 {
    const text = field orelse return null;
    if (text.len == 0) return null;
    var value: u32 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + (ch - '0');
        if (value > max) return null;
    }
    return if (value >= min) value else null;
}

/// `RRGGBB` (either case), `pN` or `fg`.
fn parseColor(text: []const u8) ?Color {
    if (std.mem.eql(u8, text, "fg")) return .{ .kind = .fg };
    if (text.len > 1 and text[0] == 'p') {
        return .{ .kind = .palette, .value = @intCast(decimal(text[1..], 0, 255) orelse return null) };
    }
    if (text.len != 6) return null;
    var rgb: u24 = 0;
    for (text) |ch| {
        const digit = std.fmt.charToDigit(ch, 16) catch return null;
        rgb = (rgb << 4) | digit;
    }
    return .{ .kind = .rgb, .value = rgb };
}

/// `KEY=VALUE` with `KEY` in `[a-z-]+` and `VALUE` in `[a-z0-9-]+`.
fn isExtensionField(field: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, field, '=') orelse return false;
    if (eq == 0 or eq + 1 == field.len) return false;
    for (field[0..eq]) |ch| {
        if (!std.ascii.isLower(ch) and ch != '-') return false;
    }
    for (field[eq + 1 ..]) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return true;
}

// ── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "segment bits and named masks match the protocol table" {
    try testing.expectEqual(@as(Mask, 1), Segment.top_left.mask());
    try testing.expectEqual(@as(Mask, 2048), Segment.v_bottom.mask());
    try testing.expectEqual(@as(Mask, 3), group.top);
    try testing.expectEqual(@as(Mask, 12), group.right);
    try testing.expectEqual(@as(Mask, 48), group.bottom);
    try testing.expectEqual(@as(Mask, 192), group.left);
    try testing.expectEqual(@as(Mask, 255), group.outline);
    try testing.expectEqual(@as(Mask, 768), group.horizontal);
    try testing.expectEqual(@as(Mask, 3072), group.vertical);
    try testing.expectEqual(@as(Mask, 4095), group.all);
    // The spec's quadrant example: the outline of U+2598.
    try testing.expectEqual(@as(Mask, 1345), maskOf(&.{ .top_left, .left_top, .h_left, .v_top }));
}

test "every outer half-segment has exactly one shared-edge partner, centre arms none" {
    for (segments) |seg| {
        const p = partner(seg);
        try testing.expectEqual(seg.line().onEdge(), p != null);
        if (p) |pp| {
            const back = partner(pp.segment).?;
            try testing.expectEqual(seg, back.segment);
            try testing.expectEqual(-pp.dcol, back.dcol);
            try testing.expectEqual(-pp.drow, back.drow);
            try testing.expect(pp.own_is_later != back.own_is_later);
        }
    }
}

test "shared edge: only centred pairs merge; wider wins; tie goes right or down" {
    const thin: Stroke = .{ .width = 8, .placement = .centred };
    const thick: Stroke = .{ .width = 16, .placement = .centred };
    const inside: Stroke = .{ .width = 16 };
    try testing.expect(keepsSharedEdge(thick, thin, false));
    try testing.expect(!keepsSharedEdge(thin, thick, true));
    try testing.expect(keepsSharedEdge(thin, thin, true));
    try testing.expect(!keepsSharedEdge(thin, thin, false));
    try testing.expect(keepsSharedEdge(thin, inside, false));
    try testing.expect(keepsSharedEdge(inside, thick, false));
    try testing.expect(keepsSharedEdge(thin, .absent, false));
    try testing.expect(!keepsSharedEdge(.absent, thin, true));
}

test "parse: every operation in its well-formed shape" {
    const pen = parse("cell-border;pen;15;32;ff8800;1;0").?;
    try testing.expectEqual(Op.pen, pen.op);
    try testing.expectEqual(@as(Mask, 15), pen.mask);
    try testing.expectEqual(@as(u7, 32), pen.stroke.width);
    try testing.expectEqual(Placement.centred, pen.stroke.placement);
    try testing.expectEqual(Layer.below_text, pen.stroke.layer);
    try testing.expectEqual(Color{ .kind = .rgb, .value = 0xff8800 }, pen.stroke.color);

    const set = parse("cell-border;set;4095;1;p12;0;1;3;7").?;
    try testing.expectEqual(Op.set, set.op);
    try testing.expectEqual(Color{ .kind = .palette, .value = 12 }, set.stroke.color);
    try testing.expectEqual(Layer.above_text, set.stroke.layer);
    try testing.expectEqual(@as(u16, 3), set.rows);
    try testing.expectEqual(@as(u16, 7), set.cols);

    const clear = parse("cell-border;clear;48;65535;1").?;
    try testing.expectEqual(Op.clear, clear.op);
    try testing.expect(!clear.stroke.present());
    try testing.expectEqual(@as(u16, 65535), clear.rows);

    try testing.expectEqual(Op.@"pen-clear", parse("cell-border;pen-clear;1").?.op);
    try testing.expectEqual(Op.q, parse("cell-border;q").?.op);
    try testing.expectEqual(Color{ .kind = .fg }, parse("cell-border;pen;1;1;fg;0;0").?.stroke.color);
}

test "parse: leading zeros, either-case hex, unknown extension keys" {
    const cmd = parse("cell-border;pen;0003;064;AbCdEf;01;00;style=double;priority=3;future-key=x-1").?;
    try testing.expectEqual(@as(Mask, 3), cmd.mask);
    try testing.expectEqual(@as(u7, 64), cmd.stroke.width);
    try testing.expectEqual(@as(u24, 0xabcdef), cmd.stroke.color.value);
    try testing.expectEqual(Placement.centred, cmd.stroke.placement);
    try testing.expectEqual(Color{ .kind = .palette, .value = 7 }, parse("cell-border;pen;1;1;p007;0;0").?.stroke.color);
    try testing.expect(parse("cell-border;set;1;1;fg;0;0;1;1;outside=ff00aa") != null);
}

test "parse: malformed commands are ignored whole" {
    const bad = [_][]const u8{
        "",
        "cell-border",
        "cell-borders;q",
        "Cell-border;q",
        "cell-border;q;1",
        "cell-border;q;style=solid",
        "cell-border;bogus;1",
        "cell-border;pen-round;15",
        "cell-border;round;15;1;1",
        "cell-border;pen",
        "cell-border;pen;0;1;fg;0;0",
        "cell-border;pen;4096;1;fg;0;0",
        "cell-border;pen;1;0;fg;0;0",
        "cell-border;pen;1;65;fg;0;0",
        "cell-border;pen;1;1;fg;2;0",
        "cell-border;pen;1;1;fg;0;2",
        "cell-border;pen;1;1;fg;0",
        "cell-border;pen;+1;1;fg;0;0",
        "cell-border;pen;-1;1;fg;0;0",
        "cell-border;pen; 1;1;fg;0;0",
        "cell-border;pen;1;1;FG;0;0",
        "cell-border;pen;1;1;p256;0;0",
        "cell-border;pen;1;1;p;0;0",
        "cell-border;pen;1;1;12345;0;0",
        "cell-border;pen;1;1;12345g;0;0",
        "cell-border;pen;1;1;fg;0;0;",
        "cell-border;pen;1;1;fg;0;0;style",
        "cell-border;pen;1;1;fg;0;0;=x",
        "cell-border;pen;1;1;fg;0;0;style=",
        "cell-border;pen;1;1;fg;0;0;Style=solid",
        "cell-border;pen;1;1;fg;0;0;outside=FF00AA",
        "cell-border;pen;1;1;fg;0;0;key_x=1",
        "cell-border;pen-clear;1;style=solid",
        "cell-border;pen-clear;0",
        "cell-border;set;1;1;fg;0;0;0;1",
        "cell-border;set;1;1;fg;0;0;1;65536",
        "cell-border;set;1;1;fg;0;0;1",
        "cell-border;clear;1;1",
        "cell-border;clear;1;1;1;style=solid",
    };
    for (bad) |body| {
        if (parse(body) != null) {
            std.debug.print("accepted malformed payload: {s}\n", .{body});
            return error.TestUnexpectedResult;
        }
    }
}

test "parse: payloads past 256 bytes are ignored" {
    const head = "cell-border;pen;1;1;fg;0;0;a=";
    var long: [max_payload_len + 1]u8 = undefined;
    @memcpy(long[0..head.len], head);
    @memset(long[head.len..], 'b');
    try testing.expect(parse(long[0..max_payload_len]) != null);
    try testing.expect(parse(&long) == null);
}

test "Stroke.valid accepts exactly what the parser produces" {
    try testing.expect(Stroke.absent.valid());
    try testing.expect(parse("cell-border;pen;1;64;p255;1;1").?.stroke.valid());
    try testing.expect(!(Stroke{ .width = 65 }).valid());
    try testing.expect(!(Stroke{ .width = 0, .placement = .centred }).valid());
    try testing.expect(!(Stroke{ .width = 1, .color = .{ .kind = .palette, .value = 256 } }).valid());
    try testing.expect(!(Stroke{ .width = 1, .color = .{ .kind = .fg, .value = 1 } }).valid());
    try testing.expect(!(Stroke{ .width = 1, .color = .{ .kind = @enumFromInt(3) } }).valid());
    try testing.expect(!(Stroke{ .width = 1, ._pad = 1 }).valid());
}

test "Command.apply replaces only the selected segments" {
    const red = parse("cell-border;pen;3;8;ff0000;0;0").?;
    const blue = parse("cell-border;pen;1;8;0000ff;0;0").?;
    var set = red.apply(empty);
    set = blue.apply(set);
    try testing.expectEqual(@as(u24, 0x0000ff), set[@intFromEnum(Segment.top_left)].color.value);
    try testing.expectEqual(@as(u24, 0xff0000), set[@intFromEnum(Segment.top_right)].color.value);
    set = parse("cell-border;pen-clear;1").?.apply(set);
    try testing.expectEqual(@as(Mask, 2), presentMask(set));
    set = parse("cell-border;pen-clear;4095").?.apply(set);
    try testing.expect(isEmpty(set));
}

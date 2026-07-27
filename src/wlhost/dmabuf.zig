//! Pure-Zig linux-dmabuf metadata, parameter validation and v4
//! feedback format tables.

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

pub const DRM_FORMAT_ARGB8888: u32 = 0x34325241; // 'AR24'
pub const DRM_FORMAT_XRGB8888: u32 = 0x34325258; // 'XR24'
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;

pub const FLAG_Y_INVERT: u32 = 1 << 0;
pub const FLAG_INTERLACED: u32 = 1 << 1;
pub const FLAG_BOTTOM_FIRST: u32 = 1 << 2;
pub const KNOWN_FLAGS: u32 = FLAG_Y_INVERT | FLAG_INTERLACED | FLAG_BOTTOM_FIRST;
pub const SUPPORTED_FLAGS: u32 = FLAG_Y_INVERT;

pub const MAX_PLANES = 4;
pub const MAX_DIMENSION: u32 = 16 * 1024;
pub const MAX_BUFFER_BYTES: u64 = 256 * 1024 * 1024;

pub const Error = error{
    AlreadyUsed,
    PlaneIndex,
    PlaneSet,
    ModifierMismatch,
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    InvalidFlags,
    InvalidPlaneCount,
    InvalidStride,
    Overflow,
    OutOfBounds,
    ResourceLimit,
};

/// Describes one plane without taking ownership of its file descriptor.
pub const Plane = struct {
    offset: u32,
    stride: u32,
    modifier: u64,
    resource_size: u64 = std.math.maxInt(u64),
};

/// Describes one format/modifier pair exposed by an importer.
pub const Capability = struct {
    format: u32,
    modifier: u64,
    external_only: bool = false,
};

/// Reports whether a format/modifier tuple is present regardless of its external-only property.
pub fn contains(capabilities: []const Capability, format: u32, modifier: u64) bool {
    for (capabilities) |capability| {
        if (capability.format == format and capability.modifier == modifier) return true;
    }
    return false;
}

/// Appends format/modifier pairs not already present in the destination.
pub fn appendUnique(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Capability),
    additions: []const Capability,
) !void {
    for (additions) |addition| {
        if (!contains(out.items, addition.format, addition.modifier))
            try out.append(allocator, addition);
    }
}

pub const linear_capabilities = [_]Capability{
    .{ .format = DRM_FORMAT_ARGB8888, .modifier = DRM_FORMAT_MOD_LINEAR },
    .{ .format = DRM_FORMAT_XRGB8888, .modifier = DRM_FORMAT_MOD_LINEAR },
};

/// Bytes per zwp_linux_dmabuf_feedback_v1 format-table entry:
/// u32 format, u32 padding, u64 modifier (host byte order).
pub const table_entry_size = 16;

/// A capability that belongs in the v4 format table: MOD_INVALID
/// exists only for the pre-v3 legacy announcement and has no meaning
/// in a table, and a format we cannot turn into CPU pixels would
/// invite allocations that create_immed then rejects.
fn tableEligible(capability: Capability) bool {
    return capability.modifier != DRM_FORMAT_MOD_INVALID and
        shmFormat(capability.format) != null;
}

/// Number of entries appendFormatTable would write. Zero means the
/// v4 feedback would be empty, so v4 must not be announced at all.
pub fn tableEntryCount(capabilities: []const Capability) usize {
    var n: usize = 0;
    for (capabilities) |capability| {
        if (tableEligible(capability)) n += 1;
    }
    return n;
}

/// Serialize capabilities as the v4 feedback format table. Entry i
/// corresponds to index i in a tranche_formats array.
pub fn appendFormatTable(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    capabilities: []const Capability,
) !void {
    for (capabilities) |capability| {
        if (!tableEligible(capability)) continue;
        // The client mmaps this table and reads it as a C struct
        // array, so entries are HOST byte order (like the Wayland
        // wire format itself), not the pipe's little-endian fields.
        var entry: [table_entry_size]u8 = undefined;
        std.mem.writeInt(u32, entry[0..4], capability.format, native_endian);
        std.mem.writeInt(u32, entry[4..8], 0, native_endian);
        std.mem.writeInt(u64, entry[8..16], capability.modifier, native_endian);
        try out.appendSlice(allocator, &entry);
    }
}

pub fn shmFormat(format: u32) ?u32 {
    return switch (format) {
        DRM_FORMAT_ARGB8888 => 0,
        DRM_FORMAT_XRGB8888 => 1,
        else => null,
    };
}

/// Validated metadata needed to import a supported single-plane buffer.
pub const BufferInfo = struct {
    width: u32,
    height: u32,
    format: u32,
    flags: u32,
    planes: [MAX_PLANES]?Plane,
    plane_count: u8,
    plane: Plane,
    required_sizes: [MAX_PLANES]u64,
    /// End-exclusive byte extent required in the plane resource.
    required_size: u64,
};

/// Accumulates the single-use state of a zwp_linux_buffer_params_v1 object.
pub const Params = struct {
    planes: [MAX_PLANES]?Plane = .{null} ** MAX_PLANES,
    modifier: ?u64 = null,
    used: bool = false,

    /// Adds a plane in any order while enforcing index and modifier invariants.
    pub fn add(self: *Params, index: u32, plane: Plane) Error!void {
        if (self.used) return Error.AlreadyUsed;
        if (index >= MAX_PLANES) return Error.PlaneIndex;
        const i: usize = @intCast(index);
        if (self.planes[i] != null) return Error.PlaneSet;
        if (self.modifier) |modifier| {
            if (modifier != plane.modifier) return Error.ModifierMismatch;
        }

        self.planes[i] = plane;
        if (self.modifier == null) self.modifier = plane.modifier;
    }

    /// Returns one plane or null for an unset or out-of-range index.
    pub fn getPlane(self: *const Params, index: u32) ?Plane {
        if (index >= MAX_PLANES) return null;
        return self.planes[@intCast(index)];
    }

    /// Consumes the params and validates an ARGB8888 or XRGB8888 buffer.
    pub fn create(self: *Params, width: i32, height: i32, format: u32, flags: u32) Error!BufferInfo {
        if (self.used) return Error.AlreadyUsed;
        self.used = true;

        if (format != DRM_FORMAT_ARGB8888 and format != DRM_FORMAT_XRGB8888)
            return Error.InvalidFormat;
        if (width <= 0 or height <= 0) return Error.InvalidDimensions;

        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        if (w > MAX_DIMENSION or h > MAX_DIMENSION) return Error.ResourceLimit;
        if (flags & ~SUPPORTED_FLAGS != 0) return Error.InvalidFlags;

        const plane = self.planes[0] orelse return Error.Incomplete;
        var plane_count: usize = 0;
        var saw_gap = false;
        for (self.planes) |plane_opt| {
            if (plane_opt != null) {
                if (saw_gap) return Error.Incomplete;
                plane_count += 1;
            } else {
                saw_gap = true;
            }
        }
        if (plane.modifier == DRM_FORMAT_MOD_LINEAR and plane_count != 1)
            return Error.InvalidPlaneCount;

        const row_bytes = std.math.mul(u64, @as(u64, w), 4) catch return Error.Overflow;
        if (plane.stride < row_bytes) return Error.InvalidStride;
        if (plane.stride > MAX_BUFFER_BYTES) return Error.ResourceLimit;

        var required_sizes: [MAX_PLANES]u64 = @splat(0);
        for (self.planes[0..plane_count], 0..) |plane_opt, index| {
            const current = plane_opt.?;
            if (current.stride == 0 or current.stride > MAX_BUFFER_BYTES)
                return Error.InvalidStride;
            // Auxiliary modifier planes are opaque driver metadata; validate
            // their first row here and let EGL validate their full layout.
            const rows: u64 = if (index == 0) h else 1;
            const bytes = std.math.mul(u64, current.stride, rows) catch return Error.Overflow;
            const required = std.math.add(u64, current.offset, bytes) catch return Error.Overflow;
            if (required > MAX_BUFFER_BYTES) return Error.ResourceLimit;
            if (required > current.resource_size) return Error.OutOfBounds;
            required_sizes[index] = required;
        }
        const required_size = required_sizes[0];

        return .{
            .width = w,
            .height = h,
            .format = format,
            .flags = flags,
            .planes = self.planes,
            .plane_count = @intCast(plane_count),
            .plane = plane,
            .required_sizes = required_sizes,
            .required_size = required_size,
        };
    }
};

const t = std.testing;

fn testPlane(offset: u32, stride: u32, modifier: u64, resource_size: u64) Plane {
    return .{
        .offset = offset,
        .stride = stride,
        .modifier = modifier,
        .resource_size = resource_size,
    };
}

fn validParams() Params {
    var params = Params{};
    params.add(0, testPlane(16, 256, DRM_FORMAT_MOD_LINEAR, 16 + 256 * 64)) catch unreachable;
    return params;
}

test "planes may arrive in reverse order" {
    var params = Params{};
    var index: u32 = MAX_PLANES;
    while (index > 0) {
        index -= 1;
        try params.add(index, testPlane(index, 64, DRM_FORMAT_MOD_LINEAR, 4096));
    }

    try t.expectEqual(@as(u32, 0), params.getPlane(0).?.offset);
    try t.expectEqual(@as(u32, 3), params.getPlane(3).?.offset);
    try t.expectEqual(@as(?Plane, null), params.getPlane(MAX_PLANES));
    try t.expectError(Error.PlaneIndex, params.add(MAX_PLANES, testPlane(0, 64, 0, 4096)));
}

test "duplicate planes are rejected without replacing metadata" {
    var params = Params{};
    const first = testPlane(7, 64, DRM_FORMAT_MOD_LINEAR, 4096);
    try params.add(0, first);
    try t.expectError(Error.PlaneSet, params.add(0, testPlane(9, 128, DRM_FORMAT_MOD_INVALID, 8192)));
    try t.expectEqual(first, params.getPlane(0).?);
}

test "params are consumed by the first create attempt" {
    var params = validParams();
    _ = try params.create(64, 64, DRM_FORMAT_ARGB8888, 0);
    try t.expectError(Error.AlreadyUsed, params.create(64, 64, DRM_FORMAT_ARGB8888, 0));
    try t.expectError(Error.AlreadyUsed, params.add(1, testPlane(0, 1, 0, 1)));

    var failed = validParams();
    try t.expectError(Error.InvalidDimensions, failed.create(0, 64, DRM_FORMAT_ARGB8888, 0));
    try t.expectError(Error.AlreadyUsed, failed.create(64, 64, DRM_FORMAT_ARGB8888, 0));
}

test "all planes must use one modifier" {
    var params = Params{};
    try params.add(2, testPlane(0, 64, DRM_FORMAT_MOD_LINEAR, 4096));
    try t.expectError(
        Error.ModifierMismatch,
        params.add(0, testPlane(0, 64, DRM_FORMAT_MOD_INVALID, 4096)),
    );
    try t.expectEqual(@as(?Plane, null), params.getPlane(0));
}

test "LINEAR requires exactly plane zero while modifiers may add auxiliary planes" {
    var missing = Params{};
    try t.expectError(Error.Incomplete, missing.create(1, 1, DRM_FORMAT_ARGB8888, 0));

    var extra_linear = validParams();
    try extra_linear.add(1, testPlane(0, 256, DRM_FORMAT_MOD_LINEAR, 16 + 256 * 64));
    try t.expectError(Error.InvalidPlaneCount, extra_linear.create(64, 64, DRM_FORMAT_XRGB8888, 0));

    const modifier: u64 = 0x1234;
    var auxiliary = Params{};
    try auxiliary.add(0, testPlane(0, 256, modifier, 256 * 64));
    try auxiliary.add(1, testPlane(4096, 64, modifier, 8192));
    const info = try auxiliary.create(64, 64, DRM_FORMAT_ARGB8888, 0);
    try t.expectEqual(@as(u8, 2), info.plane_count);
    try t.expectEqual(@as(u64, 4160), info.required_sizes[1]);

    var gap = Params{};
    try gap.add(0, testPlane(0, 256, modifier, 256 * 64));
    try gap.add(2, testPlane(4096, 64, modifier, 8192));
    try t.expectError(Error.Incomplete, gap.create(64, 64, DRM_FORMAT_ARGB8888, 0));
}

test "checked extents reject overflow-sized and short resources" {
    var short = Params{};
    try short.add(0, testPlane(32, 64, DRM_FORMAT_MOD_LINEAR, 32 + 64 * 3 + 63));
    try t.expectError(Error.OutOfBounds, short.create(16, 4, DRM_FORMAT_ARGB8888, 0));

    var huge_stride = Params{};
    try huge_stride.add(0, testPlane(0, std.math.maxInt(u32), DRM_FORMAT_MOD_LINEAR, std.math.maxInt(u64)));
    try t.expectError(Error.ResourceLimit, huge_stride.create(1, 2, DRM_FORMAT_ARGB8888, 0));

    var huge_dimension = validParams();
    try t.expectError(
        Error.ResourceLimit,
        huge_dimension.create(@intCast(MAX_DIMENSION + 1), 1, DRM_FORMAT_ARGB8888, 0),
    );
}

test "valid byte extent includes offset and full final stride" {
    var params = Params{};
    try params.add(0, testPlane(8, 20, DRM_FORMAT_MOD_LINEAR, 48));
    const info = try params.create(4, 2, DRM_FORMAT_XRGB8888, 0);
    try t.expectEqual(@as(u64, 48), info.required_size);
}

test "y-invert is the only supported flag" {
    var inverted = validParams();
    const inverted_info = try inverted.create(64, 64, DRM_FORMAT_ARGB8888, FLAG_Y_INVERT);
    try t.expectEqual(FLAG_Y_INVERT, inverted_info.flags);

    var interlaced = validParams();
    try t.expectError(Error.InvalidFlags, interlaced.create(64, 64, DRM_FORMAT_XRGB8888, FLAG_INTERLACED));
}

test "unknown and inconsistent flags are rejected" {
    var unknown = validParams();
    try t.expectError(Error.InvalidFlags, unknown.create(64, 64, DRM_FORMAT_ARGB8888, 1 << 31));

    var bottom_only = validParams();
    try t.expectError(
        Error.InvalidFlags,
        bottom_only.create(64, 64, DRM_FORMAT_ARGB8888, FLAG_BOTTOM_FIRST),
    );
}

test "capability lookup matches format and modifier" {
    const capabilities = [_]Capability{
        .{ .format = DRM_FORMAT_ARGB8888, .modifier = DRM_FORMAT_MOD_LINEAR },
        .{
            .format = DRM_FORMAT_XRGB8888,
            .modifier = DRM_FORMAT_MOD_INVALID,
            .external_only = true,
        },
    };
    try t.expect(contains(&capabilities, DRM_FORMAT_ARGB8888, DRM_FORMAT_MOD_LINEAR));
    try t.expect(contains(&capabilities, DRM_FORMAT_XRGB8888, DRM_FORMAT_MOD_INVALID));
    try t.expect(!contains(&capabilities, DRM_FORMAT_XRGB8888, DRM_FORMAT_MOD_LINEAR));
}

test "capability union preserves LINEAR and deduplicates importer pairs" {
    var capabilities: std.ArrayList(Capability) = .empty;
    defer capabilities.deinit(t.allocator);
    try appendUnique(t.allocator, &capabilities, &linear_capabilities);
    try appendUnique(t.allocator, &capabilities, &.{
        .{ .format = DRM_FORMAT_ARGB8888, .modifier = DRM_FORMAT_MOD_LINEAR },
        .{ .format = DRM_FORMAT_ARGB8888, .modifier = 0x1234 },
    });
    try t.expectEqual(@as(usize, 3), capabilities.items.len);
    try t.expect(contains(capabilities.items, DRM_FORMAT_XRGB8888, DRM_FORMAT_MOD_LINEAR));
    try t.expect(contains(capabilities.items, DRM_FORMAT_ARGB8888, 0x1234));
}

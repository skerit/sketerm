//! CEF command-line switches that must be coalesced rather than repeated.

const std = @import("std");

pub const disable_features_prefix = "--disable-features=";
pub const read_anything_feature = "ImmersiveReadAnything";

/// Returns the feature list carried by a Chromium disable-features switch.
pub fn disableFeaturesValue(arg: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, disable_features_prefix)) return null;
    return arg[disable_features_prefix.len..];
}

pub const Builder = struct {
    out: []u8,
    len: usize,
    have_read_anything: bool = false,

    pub const Error = error{NoSpace};

    /// Starts one merged disable-features switch in caller-owned storage.
    pub fn init(out: []u8) Error!Builder {
        if (out.len <= disable_features_prefix.len) return error.NoSpace;
        @memcpy(out[0..disable_features_prefix.len], disable_features_prefix);
        return .{ .out = out, .len = disable_features_prefix.len };
    }

    /// Adds a comma-separated feature list without changing feature order.
    pub fn add(self: *Builder, value: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |feature| {
            if (feature.len == 0) continue;
            if (std.mem.eql(u8, feature, read_anything_feature)) self.have_read_anything = true;
            const separator: usize = @intFromBool(self.len != disable_features_prefix.len);
            if (feature.len > self.out.len -| self.len -| separator -| 1) return error.NoSpace;
            if (separator != 0) {
                self.out[self.len] = ',';
                self.len += 1;
            }
            @memcpy(self.out[self.len..][0..feature.len], feature);
            self.len += feature.len;
        }
    }

    /// Appends the compatibility disable when absent and terminates the switch.
    pub fn finish(self: *Builder) Error![:0]u8 {
        if (!self.have_read_anything) try self.add(read_anything_feature);
        if (self.len >= self.out.len) return error.NoSpace;
        self.out[self.len] = 0;
        return self.out[0..self.len :0];
    }
};

test "CEF disable-features builder adds the Read Anything workaround" {
    var buf: [128]u8 = undefined;
    var builder = try Builder.init(&buf);
    try std.testing.expectEqualStrings(
        "--disable-features=ImmersiveReadAnything",
        try builder.finish(),
    );
}

test "CEF disable-features builder preserves and coalesces existing values" {
    var buf: [256]u8 = undefined;
    var builder = try Builder.init(&buf);
    try builder.add("BackForwardCache,Translate");
    try builder.add("OptimizationHints");
    try std.testing.expectEqualStrings(
        "--disable-features=BackForwardCache,Translate,OptimizationHints,ImmersiveReadAnything",
        try builder.finish(),
    );
}

test "CEF disable-features builder does not duplicate the workaround" {
    var buf: [256]u8 = undefined;
    var builder = try Builder.init(&buf);
    try builder.add("BackForwardCache,ImmersiveReadAnything");
    try builder.add("");
    try std.testing.expectEqualStrings(
        "--disable-features=BackForwardCache,ImmersiveReadAnything",
        try builder.finish(),
    );
    try std.testing.expectEqualStrings(
        "BackForwardCache,ImmersiveReadAnything",
        disableFeaturesValue("--disable-features=BackForwardCache,ImmersiveReadAnything").?,
    );
    try std.testing.expect(disableFeaturesValue("--enable-features=BackForwardCache") == null);
}

test "CEF disable-features builder reports insufficient storage" {
    var buf: [32]u8 = undefined;
    var builder = try Builder.init(&buf);
    try std.testing.expectError(error.NoSpace, builder.finish());
}

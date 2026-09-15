//! Mandatory CEF startup switches and coalesced feature overrides.

const std = @import("std");

pub const disable_features_prefix = "--disable-features=";
pub const read_anything_feature = "ImmersiveReadAnything";
const no_first_run = "--no-first-run";

/// Copy argv while reserving the helper's mandatory startup switches.
pub fn withDefaults(argv: []const [*:0]const u8, disable_features: [:0]u8, buf: *[64][*c]u8) [][*c]u8 {
    var n: usize = 0;
    for (argv) |a| {
        const arg = std.mem.span(a);
        if (disableFeaturesValue(arg) != null or std.mem.eql(u8, arg, no_first_run)) continue;
        if (n + 2 >= buf.len) break;
        buf[n] = @ptrCast(@constCast(a));
        n += 1;
    }
    buf[n] = @ptrCast(disable_features.ptr);
    // AIDEV-NOTE: CEF's first-run UI can block cef_initialize forever on a
    // fresh cache, before our control socket exists. Sketerm owns the UI;
    // Chromium must never start its onboarding, even on a Wayland helper.
    buf[n + 1] = @ptrCast(@constCast(no_first_run));
    return buf[0 .. n + 2];
}

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

test "CEF startup defaults survive fresh, inherited and full argument lists" {
    const t = std.testing;
    var storage: [128]u8 = undefined;
    var builder = try Builder.init(&storage);
    const features = try builder.finish();
    var buf: [64][*c]u8 = undefined;

    const fresh = withDefaults(&.{ "helper", "--socket", "/tmp/browser.sock" }, features, &buf);
    try t.expectEqual(@as(usize, 5), fresh.len);
    try t.expectEqualStrings("helper", std.mem.span(fresh[0]));
    try t.expectEqualStrings("/tmp/browser.sock", std.mem.span(fresh[2]));
    try t.expectEqualStrings(features, std.mem.span(fresh[3]));
    try t.expectEqualStrings(no_first_run, std.mem.span(fresh[4]));

    const inherited = withDefaults(&.{ "helper", no_first_run, "--type=renderer", features.ptr }, features, &buf);
    try t.expectEqual(@as(usize, 4), inherited.len);
    try t.expectEqualStrings("--type=renderer", std.mem.span(inherited[1]));
    try t.expectEqualStrings(features, std.mem.span(inherited[2]));
    try t.expectEqualStrings(no_first_run, std.mem.span(inherited[3]));

    const many: [80][*:0]const u8 = @splat("--extra");
    const full = withDefaults(&many, features, &buf);
    try t.expectEqual(buf.len, full.len);
    try t.expectEqualStrings(features, std.mem.span(full[full.len - 2]));
    try t.expectEqualStrings(no_first_run, std.mem.span(full[full.len - 1]));
}

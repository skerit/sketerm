const std = @import("std");
const Config = @import("../config.zig").Config;
const ProfileSettings = @import("../config.zig").ProfileSettings;

/// Owned effective editor font inputs, independent of the config arena.
pub const OwnedFontSettings = struct {
    font_path: ?[]u8 = null,
    font_family: ?[]u8 = null,
    font_size: u16 = 14,
    line_pad: i16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const Config,
        profile_name: ?[]const u8,
    ) error{OutOfMemory}!OwnedFontSettings {
        return initFromSettings(allocator, cfg.profileSettings(profile_name orelse ""));
    }

    fn initFromSettings(
        allocator: std.mem.Allocator,
        settings: *const ProfileSettings,
    ) error{OutOfMemory}!OwnedFontSettings {
        const explicit_editor_family = settings.editor_font_family.len > 0;
        const family = if (explicit_editor_family)
            settings.editor_font_family
        else
            settings.font_family;
        const path = if (explicit_editor_family) null else settings.font_path;

        var out = OwnedFontSettings{
            .font_size = if (settings.editor_font_size > 0)
                settings.editor_font_size
            else
                settings.font_size,
            .line_pad = settings.line_pad_px,
        };
        errdefer out.deinit(allocator);
        if (path) |value| out.font_path = try allocator.dupe(u8, value);
        if (family.len > 0) out.font_family = try allocator.dupe(u8, family);
        return out;
    }

    pub fn deinit(self: *OwnedFontSettings, allocator: std.mem.Allocator) void {
        if (self.font_path) |value| allocator.free(value);
        if (self.font_family) |value| allocator.free(value);
        self.* = .{};
    }

    /// Replace every input together, leaving the old bundle intact on OOM.
    pub fn sync(
        self: *OwnedFontSettings,
        allocator: std.mem.Allocator,
        cfg: *const Config,
        profile_name: ?[]const u8,
    ) error{OutOfMemory}!bool {
        var next = try init(allocator, cfg, profile_name);
        if (eql(self, &next)) {
            next.deinit(allocator);
            return false;
        }
        self.deinit(allocator);
        self.* = next;
        return true;
    }

    fn eql(a: *const OwnedFontSettings, b: *const OwnedFontSettings) bool {
        return a.font_size == b.font_size and
            a.line_pad == b.line_pad and
            eqlOpt(a.font_path, b.font_path) and
            eqlOpt(a.font_family, b.font_family);
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "editor font config owns set change and removed paths with layout decisions" {
    const t = std.testing;
    const allocator = t.allocator;
    var font = OwnedFontSettings{};
    defer font.deinit(allocator);
    var atlas_rebuilds: u32 = 0;
    var layout_rebuilds: u32 = 0;

    const configs = [_][]const u8{
        "font = /fonts/one.ttf\nline_pad_px = 2\n",
        "font = /fonts/two.ttf\nline_pad_px = 2\n",
        "line_pad_px = -1\n",
        "line_pad_px = 4\n",
    };
    for (configs, 0..) |body, index| {
        var cfg = try Config.loadFromBytes(allocator, body);
        const changed = try font.sync(allocator, &cfg, null);
        if (changed) {
            atlas_rebuilds += 1;
            layout_rebuilds += 1;
        }
        cfg.deinit();

        switch (index) {
            0 => try t.expectEqualStrings("/fonts/one.ttf", font.font_path.?),
            1 => try t.expectEqualStrings("/fonts/two.ttf", font.font_path.?),
            2, 3 => try t.expect(font.font_path == null),
            else => unreachable,
        }
    }
    try t.expectEqual(@as(i16, 4), font.line_pad);
    try t.expectEqual(@as(u32, 4), atlas_rebuilds);
    try t.expectEqual(atlas_rebuilds, layout_rebuilds);

    var unchanged = try Config.loadFromBytes(allocator, configs[3]);
    defer unchanged.deinit();
    try t.expect(!try font.sync(allocator, &unchanged, null));
    try t.expectEqual(@as(u32, 4), atlas_rebuilds);
}

test "editor font config explicit family suppresses and restores profile path" {
    const t = std.testing;
    var cfg = Config{};
    cfg.settings.font_path = "/fonts/terminal.ttf";
    cfg.settings.font_family = "Terminal Mono";
    cfg.settings.font_size = 13;
    cfg.settings.line_pad_px = 3;
    cfg.settings.editor_font_family = "Editor Sans";
    cfg.settings.editor_font_size = 17;

    var font = try OwnedFontSettings.init(t.allocator, &cfg, null);
    defer font.deinit(t.allocator);
    try t.expect(font.font_path == null);
    try t.expectEqualStrings("Editor Sans", font.font_family.?);
    try t.expectEqual(@as(u16, 17), font.font_size);
    try t.expectEqual(@as(i16, 3), font.line_pad);

    cfg.settings.editor_font_family = "";
    cfg.settings.editor_font_size = 0;
    try t.expect(try font.sync(t.allocator, &cfg, null));
    try t.expectEqualStrings("/fonts/terminal.ttf", font.font_path.?);
    try t.expectEqualStrings("Terminal Mono", font.font_family.?);
    try t.expectEqual(@as(u16, 13), font.font_size);
}

test "editor font config resolves pane profiles and standalone default consistently" {
    const t = std.testing;
    const body =
        \\font = /fonts/default.ttf
        \\font_family = Default Mono
        \\line_pad_px = 1
        \\[profile.work]
        \\font = /fonts/work.ttf
        \\font_family = Work Mono
        \\line_pad_px = 6
    ;
    var cfg = try Config.loadFromBytes(t.allocator, body);

    var standalone = try OwnedFontSettings.init(t.allocator, &cfg, null);
    defer standalone.deinit(t.allocator);
    var default_pane = try OwnedFontSettings.init(t.allocator, &cfg, "");
    defer default_pane.deinit(t.allocator);
    var profile_pane = try OwnedFontSettings.init(t.allocator, &cfg, "work");
    defer profile_pane.deinit(t.allocator);
    cfg.deinit();

    try t.expectEqualStrings(standalone.font_path.?, default_pane.font_path.?);
    try t.expectEqualStrings(standalone.font_family.?, default_pane.font_family.?);
    try t.expectEqual(standalone.line_pad, default_pane.line_pad);
    try t.expectEqualStrings("/fonts/work.ttf", profile_pane.font_path.?);
    try t.expectEqualStrings("Work Mono", profile_pane.font_family.?);
    try t.expectEqual(@as(i16, 6), profile_pane.line_pad);
}

test "editor font config OOM leaves the complete old bundle unchanged" {
    const t = std.testing;
    var old_cfg = Config{};
    old_cfg.settings.font_path = "/fonts/old.ttf";
    old_cfg.settings.font_family = "Old Mono";
    old_cfg.settings.font_size = 12;
    old_cfg.settings.line_pad_px = 1;
    var new_cfg = Config{};
    new_cfg.settings.font_path = "/fonts/new.ttf";
    new_cfg.settings.font_family = "New Mono";
    new_cfg.settings.font_size = 21;
    new_cfg.settings.line_pad_px = 7;

    var baseline = t.FailingAllocator.init(t.allocator, .{});
    const baseline_allocator = baseline.allocator();
    var baseline_font = try OwnedFontSettings.init(baseline_allocator, &old_cfg, null);
    const first_sync_alloc = baseline.alloc_index;
    try t.expect(try baseline_font.sync(baseline_allocator, &new_cfg, null));
    const allocation_end = baseline.alloc_index;
    baseline_font.deinit(baseline_allocator);

    var fail_index = first_sync_alloc;
    while (fail_index < allocation_end) : (fail_index += 1) {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var font = try OwnedFontSettings.init(allocator, &old_cfg, null);
        defer font.deinit(allocator);

        try t.expectError(error.OutOfMemory, font.sync(allocator, &new_cfg, null));
        try t.expectEqualStrings("/fonts/old.ttf", font.font_path.?);
        try t.expectEqualStrings("Old Mono", font.font_family.?);
        try t.expectEqual(@as(u16, 12), font.font_size);
        try t.expectEqual(@as(i16, 1), font.line_pad);
    }
}

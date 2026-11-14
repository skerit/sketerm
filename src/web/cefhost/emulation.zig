//! Native media emulation; viewport size and device scale remain the host's geometry responsibility.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const devtools = @import("devtools_session.zig");

pub const timeout_ms: i64 = 5_000;

var fault_media_applies: u32 = 0;
var fault_media_browser: c_int = 0;
var fault_media_message: c_int = 0;

/// Zero-valued fields are unchanged patches, not resets of earlier overrides.
pub fn merge(stored: proto.ViewEmulation, patch: proto.ViewEmulation) proto.ViewEmulation {
    return .{
        .view = patch.view,
        .color_scheme = if (patch.color_scheme != 0) patch.color_scheme else stored.color_scheme,
        .reduced_motion = if (patch.reduced_motion != 0) patch.reduced_motion else stored.reduced_motion,
        .scale_x1000 = if (patch.scale_x1000 != 0) patch.scale_x1000 else stored.scale_x1000,
    };
}

pub fn hasMedia(req: proto.ViewEmulation) bool {
    return req.color_scheme != 0 or req.reduced_motion != 0;
}

/// The acknowledgment state of a view's media override, read from its DevTools session.
pub const Media = struct {
    view: u32,
    generation: u64,
    browser_id: c_int,
    message_id: c_int = 0,
    deadline_ms: i64 = 0,
    acknowledged: bool = false,
    failure: []const u8 = "",
    active: bool = true,
    /// The fault seam swallowed this message's result.
    dropped: bool = false,
    /// `Session.detaches` when this override was last submitted.
    detaches_seen: u32 = 0,
    /// The agent detached since, taking the override with it: the host submits it again.
    reapply: bool = false,

    pub fn submit(self: *Media, session: *devtools.Session, browser: *cef.cef_browser_t, req: proto.ViewEmulation, now_ms: i64) bool {
        if (!self.active or self.failure.len != 0) return false;
        if (self.message_id > 0) session.forget(self.message_id);
        self.acknowledged = false;
        self.dropped = false;
        self.reapply = false;
        self.detaches_seen = session.detaches;
        self.message_id = apply(browser, req);
        self.deadline_ms = now_ms + timeout_ms;
        if (self.message_id <= 0 or !session.track(self.message_id, 2 * timeout_ms, .memory, "")) self.failure = "media emulation submission was refused";
        return self.failure.len == 0;
    }

    pub fn expired(self: *const Media, now_ms: i64) bool {
        return self.message_id > 0 and !self.acknowledged and now_ms >= self.deadline_ms;
    }

    /// Take what the session learned since the last call.
    pub fn refresh(self: *Media, session: *devtools.Session) void {
        if (!self.active or self.failure.len != 0) return;
        if (session.browser_closed) {
            self.failure = "browser destroyed before media emulation could be retained";
            return;
        }
        if (session.detaches != self.detaches_seen) {
            // Not acknowledged until re-applied, so a navigation waits for it like for a live change.
            self.acknowledged = false;
            self.reapply = true;
            return;
        }
        if (self.message_id <= 0 or self.acknowledged or self.dropped) return;
        const out = session.outcome(self.message_id);
        if (out == .pending) return;
        // Ignore only this native result; it stays unanswered until the deadline.
        if (self.browser_id == fault_media_browser and self.message_id == fault_media_message) {
            host_mod.logLine("fault media drop browser={d} message={d} success={d}", .{ self.browser_id, self.message_id, @intFromBool(out == .ok) });
            self.dropped = true;
            return;
        }
        switch (out) {
            .pending => {},
            .ok => if (session.answeredAt(self.message_id) > self.deadline_ms) {
                self.failure = "media emulation execution acknowledgment timed out";
            } else {
                self.acknowledged = true;
            },
            .failed => self.failure = "engine rejected media emulation",
        }
    }
};

/// A positive ID means queued only; `Media` waits for the matching execution result.
pub fn apply(browser: *cef.cef_browser_t, req: proto.ViewEmulation) c_int {
    if (!req.valid() or !hasMedia(req)) return 0;
    const Fault = enum { reject, drop };
    const fault: ?Fault = blk: {
        const ordinal = c.getenv("SKETERM_WEB_FAULT_MEDIA_APPLY") orelse break :blk null;
        fault_media_applies +|= 1;
        const wanted = std.fmt.parseInt(u32, std.mem.span(ordinal), 10) catch break :blk null;
        if (wanted != fault_media_applies) break :blk null;
        const mode = c.getenv("SKETERM_WEB_FAULT_MEDIA_ACK") orelse break :blk .reject;
        break :blk std.meta.stringToEnum(Fault, std.mem.span(mode));
    };

    const color = switch (req.color_scheme) {
        1 => "light",
        2 => "dark",
        else => "",
    };
    const motion = switch (req.reduced_motion) {
        1 => "reduce",
        2 => "no-preference",
        else => "",
    };
    // Host supplies merged settings, so empty values only occur for features
    // that have never been overridden.
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"features\":[{{\"name\":\"prefers-color-scheme\",\"value\":\"{s}\"}}," ++
            "{{\"name\":\"prefers-reduced-motion\",\"value\":\"{s}\"}}]}}",
        .{ color, motion },
    ) catch return 0;
    const id = devtools.execute(browser, if (fault == .reject) "SketermFault.invalidMediaMethod" else "Emulation.setEmulatedMedia", json);
    if (fault) |mode| {
        const browser_id = (browser.get_identifier orelse return id)(browser);
        host_mod.logLine("fault media {s} browser={d} message={d}", .{ @tagName(mode), browser_id, id });
        if (mode == .drop) {
            fault_media_browser = browser_id;
            fault_media_message = id;
        }
    }
    return id;
}

test "media emulation submits native CDP parameters and rejects missing methods or failed submission" {
    try std.testing.expect(host_mod.apiHash());
    const Fake = struct {
        var host = std.mem.zeroes(cef.cef_browser_host_t);
        var calls: usize = 0;
        var releases: usize = 0;
        var result: c_int = 42;
        var params_json: [512]u8 = undefined;
        var params_len: usize = 0;
        var method_ok = false;
        var return_null = false;

        fn getHost(_: [*c]cef.cef_browser_t) callconv(.c) [*c]cef.cef_browser_host_t {
            return if (return_null) null else &host;
        }
        fn release(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            releases += 1;
            return 0;
        }
        fn execute(_: [*c]cef.cef_browser_host_t, id: c_int, method: [*c]const cef.cef_string_t, params: [*c]cef.cef_dictionary_value_t) callconv(.c) c_int {
            defer host_mod.releaseArg(params);
            calls += 1;
            var name = host_mod.Utf8.init(method);
            defer name.free();
            method_ok = id == 0 and std.mem.eql(u8, name.slice(), "Emulation.setEmulatedMedia");
            const value: *cef.cef_value_t = cef.cef_value_create() orelse return 0;
            defer host_mod.release(&value.base);
            // Keep our callback argument while set_dictionary consumes a reference.
            params.*.base.add_ref.?(&params.*.base);
            if (value.set_dictionary.?(value, params) == 0) return 0;
            value.base.add_ref.?(&value.base);
            const raw = cef.cef_write_json(value, cef.JSON_WRITER_DEFAULT);
            if (raw == null) return 0;
            defer cef.cef_string_userfree_utf16_free(raw);
            var text = host_mod.Utf8.init(raw);
            defer text.free();
            params_len = @min(params_json.len, text.slice().len);
            @memcpy(params_json[0..params_len], text.slice()[0..params_len]);
            return result;
        }
    };
    Fake.host.base.release = Fake.release;
    Fake.host.execute_dev_tools_method = Fake.execute;
    var browser = std.mem.zeroes(cef.cef_browser_t);
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .color_scheme = 2 }));
    browser.get_host = Fake.getHost;
    for ([_]u8{ 0, 1, 2 }) |color| {
        for ([_]u8{ 0, 1, 2 }) |motion| {
            if (color == 0 and motion == 0) continue;
            try std.testing.expectEqual(@as(c_int, 42), apply(&browser, .{ .view = 1, .color_scheme = color, .reduced_motion = motion, .scale_x1000 = 1500 }));
            try std.testing.expect(Fake.method_ok);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, Fake.params_json[0..Fake.params_len], .{});
            defer parsed.deinit();
            try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
            const features = parsed.value.object.get("features").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), features.len);
            try std.testing.expectEqualStrings("prefers-color-scheme", features[0].object.get("name").?.string);
            try std.testing.expectEqualStrings(switch (color) {
                1 => "light",
                2 => "dark",
                else => "",
            }, features[0].object.get("value").?.string);
            try std.testing.expectEqualStrings("prefers-reduced-motion", features[1].object.get("name").?.string);
            try std.testing.expectEqualStrings(switch (motion) {
                1 => "reduce",
                2 => "no-preference",
                else => "",
            }, features[1].object.get("value").?.string);
        }
    }
    try std.testing.expectEqual(Fake.calls, Fake.releases);
    const before = Fake.calls;
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .scale_x1000 = 1500 }));
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .color_scheme = 3 }));
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .scale_x1000 = 499 }));
    try std.testing.expectEqual(before, Fake.calls);
    Fake.result = 0;
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .color_scheme = 1 }));
    Fake.result = -1;
    try std.testing.expectEqual(@as(c_int, -1), apply(&browser, .{ .view = 1, .color_scheme = 1 }));
    Fake.host.execute_dev_tools_method = null;
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .reduced_motion = 1 }));
    Fake.return_null = true;
    try std.testing.expectEqual(@as(c_int, 0), apply(&browser, .{ .view = 1, .reduced_motion = 1 }));
}

test "zero emulation patches retain color motion and bounded geometry scale" {
    const full = proto.ViewEmulation{ .view = 7, .color_scheme = 2, .reduced_motion = 1, .scale_x1000 = 1500 };
    try std.testing.expectEqualDeep(full, merge(full, .{ .view = 7 }));
    try std.testing.expectEqualDeep(proto.ViewEmulation{
        .view = 7,
        .color_scheme = 1,
        .reduced_motion = 1,
        .scale_x1000 = 1500,
    }, merge(full, .{ .view = 7, .color_scheme = 1 }));
    try std.testing.expectEqualDeep(proto.ViewEmulation{
        .view = 7,
        .color_scheme = 2,
        .reduced_motion = 2,
        .scale_x1000 = 500,
    }, merge(full, .{ .view = 7, .reduced_motion = 2, .scale_x1000 = 500 }));
    for ([_]u16{ 500, 1000, 1500, 4000 }) |scale| try std.testing.expect((proto.ViewEmulation{ .view = 7, .scale_x1000 = scale }).valid());
    for ([_]u16{ 1, 499, 4001, 65535 }) |scale| try std.testing.expect(!(proto.ViewEmulation{ .view = 7, .scale_x1000 = scale }).valid());
}

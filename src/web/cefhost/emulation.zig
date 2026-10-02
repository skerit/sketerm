//! Native media emulation; viewport size and device scale remain the host's geometry responsibility.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const clock = @import("../../util/clock.zig");

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

/// CEF owns a transferred observer reference; the view owns another plus the registration.
pub const Observer = struct {
    observer: cef.cef_dev_tools_message_observer_t,
    refs: std.atomic.Value(u32) = .init(2),
    gpa: std.mem.Allocator,
    registration: ?*cef.cef_registration_t = null,
    view: u32,
    generation: u64,
    browser_id: c_int,
    message_id: c_int = 0,
    deadline_ms: i64 = 0,
    acknowledged: bool = false,
    failure: []const u8 = "",
    active: bool = true,
    browser_closed: bool = false,

    pub fn create(gpa: std.mem.Allocator, browser: *cef.cef_browser_t, view: u32, generation: u64) !*Observer {
        const bh: *cef.cef_browser_host_t = (browser.get_host orelse return error.EmulationRefused)(browser) orelse return error.EmulationRefused;
        defer host_mod.release(&bh.base);
        const add = bh.add_dev_tools_message_observer orelse return error.EmulationRefused;
        const id = (browser.get_identifier orelse return error.EmulationRefused)(browser);
        const self = try gpa.create(Observer);
        self.* = .{
            .observer = .{
                .base = Ref.base(),
                .on_dev_tools_method_result = onResult,
                .on_dev_tools_agent_detached = onDetached,
            },
            .gpa = gpa,
            .view = view,
            .generation = generation,
            .browser_id = id,
        };
        // add consumes one reference even when registration is refused.
        self.registration = add(bh, &self.observer);
        if (self.registration == null) {
            self.stop();
            return error.EmulationRefused;
        }
        return self;
    }

    pub fn submit(self: *Observer, browser: *cef.cef_browser_t, req: proto.ViewEmulation, now_ms: i64) bool {
        if (!self.active or self.failure.len != 0) return false;
        self.acknowledged = false;
        self.message_id = apply(browser, req);
        self.deadline_ms = now_ms + timeout_ms;
        if (self.message_id <= 0) self.failure = "media emulation submission was refused";
        return self.failure.len == 0;
    }

    pub fn expired(self: *const Observer, now_ms: i64) bool {
        return self.message_id > 0 and !self.acknowledged and now_ms >= self.deadline_ms;
    }

    pub fn closed(self: *Observer) void {
        self.browser_closed = true;
        self.failure = "browser destroyed before media emulation could be retained";
    }

    pub fn stop(self: *Observer) void {
        self.active = false;
        if (self.registration) |r| {
            self.registration = null;
            host_mod.release(&r.base);
        }
        host_mod.release(&self.observer.base);
    }

    pub fn destroyOwned(self: *Observer) void {
        self.gpa.destroy(self);
    }

    fn matches(self: *const Observer, browser: [*c]cef.cef_browser_t) bool {
        if (!self.active or browser == null) return false;
        const get_id = browser.*.get_identifier orelse return false;
        return get_id(browser) == self.browser_id;
    }

    fn onResult(arg: [*c]cef.cef_dev_tools_message_observer_t, browser: [*c]cef.cef_browser_t, id: c_int, success: c_int, _: ?*const anyopaque, _: usize) callconv(.c) void {
        defer host_mod.releaseArg(browser);
        const self = Ref.owner(@ptrCast(arg));
        if (!self.matches(browser) or self.failure.len != 0 or id <= 0 or id != self.message_id or self.acknowledged) return;
        // Ignore only this native result; the transferred browser reference still retires.
        if (self.browser_id == fault_media_browser and id == fault_media_message) {
            host_mod.logLine("fault media drop browser={d} message={d} success={d}", .{ self.browser_id, id, success });
            return;
        }
        if (self.expired(clock.nowMs())) {
            self.failure = "media emulation execution acknowledgment timed out";
            return;
        }
        if (success != 0) self.acknowledged = true else self.failure = "engine rejected media emulation";
    }

    fn onDetached(arg: [*c]cef.cef_dev_tools_message_observer_t, browser: [*c]cef.cef_browser_t) callconv(.c) void {
        defer host_mod.releaseArg(browser);
        const self = Ref.owner(@ptrCast(arg));
        if (self.matches(browser)) self.failure = "DevTools agent detached; media emulation is no longer guaranteed";
    }
};

const Ref = host_mod.HeapRef(Observer, "observer");

/// A positive ID means queued only; Observer waits for the matching execution result.
pub fn apply(browser: *cef.cef_browser_t, req: proto.ViewEmulation) c_int {
    if (!req.valid() or !hasMedia(req)) return 0;
    const get_host = browser.get_host orelse return 0;
    const bh: *cef.cef_browser_host_t = get_host(browser) orelse return 0;
    defer host_mod.release(&bh.base);
    const execute = bh.execute_dev_tools_method orelse return 0;
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
    const val: *cef.cef_value_t = cef.cef_parse_json_buffer(json.ptr, json.len, cef.JSON_PARSER_RFC) orelse return 0;
    defer host_mod.release(&val.base);
    const params: *cef.cef_dictionary_value_t = (val.get_dictionary orelse return 0)(val) orelse return 0;
    var transferred = false;
    defer if (!transferred) host_mod.release(&params.base);
    var method = std.mem.zeroes(cef.cef_string_t);
    host_mod.setStr(if (fault == .reject) "SketermFault.invalidMediaMethod" else "Emulation.setEmulatedMedia", &method);
    defer cef.cef_string_utf16_clear(&method);
    if (method.length == 0) return 0;
    // CEF consumes the dictionary reference even if submission fails.
    transferred = true;
    const id = execute(bh, 0, &method, params);
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

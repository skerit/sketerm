//! Native restrictions for a dedicated untrusted helper, configured before any document loads.

const std = @import("std");
const cef = @import("cef");
const host_mod = @import("../cefhost.zig");

/// Set once before CEF starts in every process from SKETERM_WEB_UNTRUSTED=1.
pub var enabled: bool = false;

// Chromium 152.0.7977.83: third_party/blink/renderer/platform/runtime_enabled_features.json5.
// WebTransport, Geolocation and ServiceWorker have no master runtime flag;
// native permission/request denial and the launcher's network confinement cover them.
pub const blink_features = "WebUSB,WebBluetooth,WebBluetoothGetDevices,WebBluetoothScanning," ++
    "WebBluetoothWatchAdvertisements,WebHID,Serial,WebNFC,WebOTP,DirectSockets," ++
    "Notifications,PushMessaging,BackgroundFetch,PeriodicBackgroundSync,Prerender2";

// Chromium 152: content/public/common/content_features.cc and third_party/blink/common/features.cc.
// BackForwardCache is the ONLY disable of that cache (cefargs adds just ImmersiveReadAnything):
// a cache restore activates a document without a request, past every navigation gate.
pub const chromium_features = "PrefetchProxy,PrefetchPrerenderIntegration," ++
    "Prerender2FallbackPrefetchSpecRules,AutoSpeculationRules,BackForwardCache";

const blocked_settings = [_]struct { kind: cef.cef_content_setting_types_t, pref: []const u8 }{
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_USB_GUARD, .pref = "usb_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_BLUETOOTH_GUARD, .pref = "bluetooth_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_BLUETOOTH_SCANNING, .pref = "bluetooth_scanning" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_HID_GUARD, .pref = "hid_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_SERIAL_GUARD, .pref = "serial_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS, .pref = "notifications" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_GEOLOCATION, .pref = "geolocation" },
    // CEF 152's sanitized writes are always allowed and have no registered pref.
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE, .pref = "clipboard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, .pref = "media_stream_mic" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, .pref = "media_stream_camera" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM, .pref = "camera_pan_tilt_zoom" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX, .pref = "midi_sysex" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_SENSORS, .pref = "sensors" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_NFC, .pref = "nfc_devices" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_READ_GUARD, .pref = "file_system_read_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_WRITE_GUARD, .pref = "file_system_write_guard" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_BACKGROUND_SYNC, .pref = "background_sync" },
    .{ .kind = cef.CEF_CONTENT_SETTING_TYPE_DIRECT_SOCKETS, .pref = "direct_sockets" },
};

fn addRef(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {}
fn releaseStatic(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 0;
}
fn hasRef(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 1;
}

var handler: cef.cef_request_context_handler_t = .{
    .base = .{
        .size = @sizeOf(cef.cef_request_context_handler_t),
        .add_ref = addRef,
        .release = releaseStatic,
        .has_one_ref = hasRef,
        .has_at_least_one_ref = hasRef,
    },
    .get_resource_request_handler = getResourceRequestHandler,
};

/// Pass this process-lifetime handler to every untrusted request-context factory.
pub fn contextHandler() ?*cef.cef_request_context_handler_t {
    return if (enabled) &handler else null;
}

fn getResourceRequestHandler(
    _: [*c]cef.cef_request_context_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    is_navigation: c_int,
    is_download: c_int,
    request_initiator: [*c]const cef.cef_string_t,
    disable_default_handling: [*c]c_int,
) callconv(.c) [*c]cef.cef_resource_request_handler_t {
    defer host_mod.releaseArg(browser);
    defer host_mod.releaseArg(frame);
    defer host_mod.releaseArg(request);
    if (enabled) {
        if (disable_default_handling != null) disable_default_handling.* = 1;
        return cef.sk_web_untrusted_request_handler(&host_mod.resource_request_handler, request, is_navigation, is_download, request_initiator);
    }
    // The browser's own handler takes precedence; this catches its missing lanes.
    return &host_mod.resource_request_handler;
}

/// Classify raw CEF traffic before a lossy resource-type mapping or per-view lookup.
pub fn restrictedRequest(raw_rt: cef.cef_resource_type_t, url: []const u8, has_browser: bool) ?[]const u8 {
    if (!has_browser) return "browserless";
    switch (raw_rt) {
        cef.RT_WORKER, cef.RT_SHARED_WORKER => return "worker",
        cef.RT_SERVICE_WORKER, cef.RT_NAVIGATION_PRELOAD_MAIN_FRAME, cef.RT_NAVIGATION_PRELOAD_SUB_FRAME => return "service_worker",
        cef.RT_PREFETCH => return "prefetch",
        cef.RT_FAVICON => return "favicon",
        else => {},
    }
    // CEF exposes no RT_WEBSOCKET enum; never infer it from RT_SUB_RESOURCE alone.
    if (std.ascii.startsWithIgnoreCase(url, "ws:") or
        std.ascii.startsWithIgnoreCase(url, "wss:")) return "websocket";
    return null;
}

/// Configure an initialized, fresh ephemeral context on CEF's UI thread, refusing ineffective settings.
pub fn configureContext(rc: *cef.cef_request_context_t) bool {
    if (!enabled) return true;
    const get_setting = rc.get_content_setting orelse return false;
    if (!setPref(rc, "net.network_prediction_options", .{ .integer = 2 })) return false;

    // DNS prefs can be absent from the profile (async_dns is normally local-state).
    const has_pref = rc.base.has_preference orelse return false;
    for ([_][]const u8{ "dns_prefetching.enabled", "async_dns.enabled" }) |name| {
        var key = std.mem.zeroes(cef.cef_string_t);
        host_mod.setStr(name, &key);
        defer cef.cef_string_utf16_clear(&key);
        if (has_pref(&rc.base, &key) != 0 and !setPref(rc, name, .{ .boolean = false })) return false;
    }

    // Chromium's DefaultProvider::SetWebsiteSetting silently ignores OTR writes,
    // even through SetWebsiteSetting(null, null). Its preference observer DOES
    // update the live map; write the registered pref, then query effective URLs.
    // Never put dictionary chooser-data types in this integer-setting table.
    for (blocked_settings) |setting| {
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "profile.default_content_setting_values.{s}", .{setting.pref}) catch return false;
        if (!setPref(rc, name, .{ .integer = cef.CEF_CONTENT_SETTING_VALUE_BLOCK })) return false;
        for ([_][]const u8{ "http://untrusted-check.invalid/", "https://other-check.invalid:8443/" }) |url| {
            var origin = std.mem.zeroes(cef.cef_string_t);
            host_mod.setStr(url, &origin);
            defer cef.cef_string_utf16_clear(&origin);
            var top = std.mem.zeroes(cef.cef_string_t);
            host_mod.setStr("https://top-check.invalid/", &top);
            defer cef.cef_string_utf16_clear(&top);
            if (get_setting(rc, &origin, &top, setting.kind) != cef.CEF_CONTENT_SETTING_VALUE_BLOCK) return false;
        }
    }
    return true;
}

const PrefValue = union(enum) { integer: c_int, boolean: bool };

fn setPref(rc: *cef.cef_request_context_t, name: []const u8, want: PrefValue) bool {
    const base = &rc.base;
    const set = base.set_preference orelse return false;
    const get = base.get_preference orelse return false;
    var key = std.mem.zeroes(cef.cef_string_t);
    host_mod.setStr(name, &key);
    defer cef.cef_string_utf16_clear(&key);
    var err = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&err);
    const value: *cef.cef_value_t = cef.cef_value_create() orelse return false;
    var transferred = false;
    defer if (!transferred) host_mod.release(&value.base);
    const ok = switch (want) {
        .integer => |v| (value.set_int orelse return false)(value, v),
        .boolean => |v| (value.set_bool orelse return false)(value, @intFromBool(v)),
    };
    if (ok == 0) return false;
    transferred = true;
    if (set(base, &key, value, &err) == 0) return false;
    const actual: *cef.cef_value_t = get(base, &key) orelse return false;
    defer host_mod.release(&actual.base);
    const kind = (actual.get_type orelse return false)(actual);
    return switch (want) {
        .integer => |v| kind == cef.VTYPE_INT and (actual.get_int orelse return false)(actual) == v,
        .boolean => |v| kind == cef.VTYPE_BOOL and ((actual.get_bool orelse return false)(actual) != 0) == v,
    };
}

test "untrusted raw request restrictions refuse workers without blocking document libraries" {
    try std.testing.expectEqualStrings("browserless", restrictedRequest(cef.RT_XHR, "https://example.test/", false).?);
    try std.testing.expectEqualStrings("service_worker", restrictedRequest(cef.RT_SERVICE_WORKER, "https://example.test/sw.js", true).?);
    try std.testing.expectEqualStrings("prefetch", restrictedRequest(cef.RT_PREFETCH, "https://example.test/", true).?);
    try std.testing.expectEqualStrings("favicon", restrictedRequest(cef.RT_FAVICON, "https://example.test/icon", true).?);
    for ([_][]const u8{ "ws://example.test/", "WSS://example.test/", "wSs:example.test" }) |url|
        try std.testing.expectEqualStrings("websocket", restrictedRequest(cef.RT_SUB_RESOURCE, url, true).?);
    for ([_]cef.cef_resource_type_t{ cef.RT_NAVIGATION_PRELOAD_MAIN_FRAME, cef.RT_NAVIGATION_PRELOAD_SUB_FRAME }) |rt|
        try std.testing.expectEqualStrings("service_worker", restrictedRequest(rt, "https://example.test/", true).?);
    for ([_]cef.cef_resource_type_t{ cef.RT_WORKER, cef.RT_SHARED_WORKER }) |rt|
        try std.testing.expectEqualStrings("worker", restrictedRequest(rt, "https://example.test/", true).?);
    for ([_]cef.cef_resource_type_t{ cef.RT_MAIN_FRAME, cef.RT_SUB_FRAME, cef.RT_XHR, cef.RT_SCRIPT, cef.RT_STYLESHEET, cef.RT_FONT_RESOURCE, cef.RT_SUB_RESOURCE }) |rt|
        try std.testing.expect(restrictedRequest(rt, "https://example.test/ws:resource", true) == null);
}

test "untrusted context handler is opt-in and disables fallback for browserless requests" {
    const previous = enabled;
    defer enabled = previous;
    enabled = false;
    try std.testing.expect(contextHandler() == null);
    enabled = true;
    const h = contextHandler().?;
    var fallback: c_int = 0;
    const resource = h.get_resource_request_handler.?(h, null, null, null, 0, 0, null, &fallback);
    try std.testing.expect(resource != null and resource != &host_mod.resource_request_handler);
    try std.testing.expectEqual(@as(c_int, 1), fallback);
    try std.testing.expectEqual(@as(c_int, 1), resource.*.base.has_one_ref.?(&resource.*.base));
    try std.testing.expectEqual(@as(c_int, 1), resource.*.base.release.?(&resource.*.base));
    h.base.add_ref.?(&h.base);
    try std.testing.expectEqual(@as(c_int, 0), h.base.release.?(&h.base));
    try std.testing.expectEqual(@as(c_int, 1), h.base.has_at_least_one_ref.?(&h.base));
    const Args = struct {
        var releases: usize = 0;
        fn release(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            releases += 1;
            return 0;
        }
    };
    var browser = std.mem.zeroes(cef.cef_browser_t);
    browser.base.release = Args.release;
    var frame = std.mem.zeroes(cef.cef_frame_t);
    frame.base.release = Args.release;
    var request = std.mem.zeroes(cef.cef_request_t);
    request.base.release = Args.release;
    const owned = h.get_resource_request_handler.?(h, &browser, &frame, &request, 0, 0, null, &fallback);
    try std.testing.expect(owned != null);
    host_mod.release(&owned.*.base);
    try std.testing.expectEqual(@as(usize, 3), Args.releases);
    enabled = false;
    fallback = 0;
    try std.testing.expect(h.get_resource_request_handler.?(h, null, null, null, 0, 0, null, &fallback) == &host_mod.resource_request_handler);
    try std.testing.expectEqual(@as(c_int, 0), fallback);
}

test "untrusted context configuration checks preference and effective setting readback" {
    try std.testing.expect(host_mod.apiHash());
    const Fake = struct {
        var last: ?*cef.cef_value_t = null;
        var refuse = false;
        var wrong_pref = false;
        var wrong_setting = false;
        var dns_supported = false;
        var dns_writes: usize = 0;
        var checks: usize = 0;

        fn has(_: [*c]cef.cef_preference_manager_t, _: [*c]const cef.cef_string_t) callconv(.c) c_int {
            return @intFromBool(dns_supported);
        }
        fn set(_: [*c]cef.cef_preference_manager_t, key: [*c]const cef.cef_string_t, val: [*c]cef.cef_value_t, _: [*c]cef.cef_string_t) callconv(.c) c_int {
            if (last) |old| host_mod.release(&old.base);
            last = val;
            var name = host_mod.Utf8.init(key);
            defer name.free();
            if (std.mem.endsWith(u8, name.slice(), "dns.enabled") or std.mem.eql(u8, name.slice(), "dns_prefetching.enabled")) dns_writes += 1;
            return @intFromBool(!refuse);
        }
        fn get(_: [*c]cef.cef_preference_manager_t, _: [*c]const cef.cef_string_t) callconv(.c) [*c]cef.cef_value_t {
            const val = last orelse return null;
            if (wrong_pref) _ = val.set_int.?(val, 0);
            val.base.add_ref.?(&val.base);
            return val;
        }
        fn setting(_: [*c]cef.cef_request_context_t, origin: [*c]const cef.cef_string_t, top: [*c]const cef.cef_string_t, _: cef.cef_content_setting_types_t) callconv(.c) cef.cef_content_setting_values_t {
            if (origin == null or top == null or origin.*.length == 0 or top.*.length == 0) return cef.CEF_CONTENT_SETTING_VALUE_DEFAULT;
            checks += 1;
            return if (wrong_setting) cef.CEF_CONTENT_SETTING_VALUE_ASK else cef.CEF_CONTENT_SETTING_VALUE_BLOCK;
        }
    };
    defer {
        if (Fake.last) |val| host_mod.release(&val.base);
        Fake.last = null;
    }
    const previous = enabled;
    defer enabled = previous;
    var rc = std.mem.zeroes(cef.cef_request_context_t);
    enabled = false;
    try std.testing.expect(configureContext(&rc));
    enabled = true;
    try std.testing.expect(!configureContext(&rc));
    rc.base.has_preference = Fake.has;
    rc.base.set_preference = Fake.set;
    rc.base.get_preference = Fake.get;
    rc.get_content_setting = Fake.setting;
    try std.testing.expect(configureContext(&rc));
    try std.testing.expectEqual(blocked_settings.len * 2, Fake.checks);
    try std.testing.expectEqual(@as(usize, 0), Fake.dns_writes);
    Fake.dns_supported = true;
    try std.testing.expect(configureContext(&rc));
    try std.testing.expectEqual(@as(usize, 2), Fake.dns_writes);
    Fake.refuse = true;
    try std.testing.expect(!configureContext(&rc));
    Fake.refuse = false;
    Fake.wrong_pref = true;
    try std.testing.expect(!configureContext(&rc));
    Fake.wrong_pref = false;
    Fake.wrong_setting = true;
    try std.testing.expect(!configureContext(&rc));
    Fake.wrong_setting = false;
    rc.base.get_preference = null;
    try std.testing.expect(!configureContext(&rc));
    rc.base.get_preference = Fake.get;
    rc.base.set_preference = null;
    try std.testing.expect(!configureContext(&rc));
    rc.base.set_preference = Fake.set;
    rc.base.has_preference = null;
    try std.testing.expect(!configureContext(&rc));
}

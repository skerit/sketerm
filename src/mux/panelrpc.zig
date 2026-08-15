//! Structural validation for panel presenter requests and replies.

const std = @import("std");
const wire = @import("wire.zig");

pub const EventEpoch = wire.SessionOriginId;
pub const validEventEpoch = wire.validSessionOriginId;

pub const OpenSessionRequest = struct {
    cmd: []const u8,
    mux_session: []const u8,
    mux_origin_id: []const u8,
    request_token: []const u8,
};

pub const MAX_REQUEST_TOKEN: usize = 128;

pub fn validRequestToken(token: []const u8) bool {
    if (token.len == 0 or token.len > MAX_REQUEST_TOKEN) return false;
    for (token) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// Parse the authority-bearing open request with an exact field allowlist.
pub fn parseOpenSessionRequest(
    allocator: std.mem.Allocator,
    json: []const u8,
) !std.json.Parsed(OpenSessionRequest) {
    var value = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.InvalidJson;
    defer value.deinit();
    if (value.value != .object) return error.RequestNotObject;
    if (value.value.object.count() != 4) return error.UnexpectedField;
    var it = value.value.object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        if (!std.mem.eql(u8, key, "cmd") and
            !std.mem.eql(u8, key, "mux_session") and
            !std.mem.eql(u8, key, "mux_origin_id") and
            !std.mem.eql(u8, key, "request_token")) return error.UnexpectedField;
    }

    const parsed = std.json.parseFromSlice(OpenSessionRequest, allocator, json, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidJson;
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.cmd, "panel-open-session")) return error.InvalidCommand;
    if (parsed.value.mux_session.len < 1 or parsed.value.mux_session.len > wire.MAX_SESSION_NAME)
        return error.InvalidSession;
    if (!wire.validSessionOriginId(parsed.value.mux_origin_id)) return error.InvalidOriginId;
    if (!validRequestToken(parsed.value.request_token)) return error.InvalidRequestToken;
    return parsed;
}

pub const Op = enum {
    show,
    patch,
    get,
    events,
    reliable_events,
    list,
    close,
    open_session,
    unknown,
};

pub fn opFromCommand(command: []const u8) Op {
    if (std.mem.eql(u8, command, "panel-show")) return .show;
    if (std.mem.eql(u8, command, "panel-patch")) return .patch;
    if (std.mem.eql(u8, command, "panel-get")) return .get;
    if (std.mem.eql(u8, command, "panel-events")) return .events;
    if (std.mem.eql(u8, command, "panel-events-reliable")) return .reliable_events;
    if (std.mem.eql(u8, command, "panel-list")) return .list;
    if (std.mem.eql(u8, command, "panel-close")) return .close;
    if (std.mem.eql(u8, command, "panel-open-session")) return .open_session;
    return .unknown;
}

fn positiveInteger(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .integer and v.integer > 0;
}

fn requiredEventEpoch(value: std.json.Value) !void {
    if (value != .string or !validEventEpoch(value.string)) return error.InvalidEventEpoch;
}

fn optionalEventEpoch(object: std.json.ObjectMap) !void {
    if (object.get("event_epoch")) |epoch| try requiredEventEpoch(epoch);
}

/// Validate reliable acknowledgement identity before the queue is mutated.
pub fn validateReliableEventsRequest(
    ack: u64,
    requested_epoch: ?[]const u8,
    current_epoch: []const u8,
) !void {
    const requested = requested_epoch orelse "";
    if (requested.len == 0) {
        if (ack != 0) return error.MissingEventEpoch;
        return;
    }
    if (!validEventEpoch(requested)) return error.InvalidEventEpoch;
    if (!validEventEpoch(current_epoch) or !std.mem.eql(u8, requested, current_epoch))
        return error.EventEpochMismatch;
}

fn validComponentId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    switch (id[0]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    }
    for (id) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn validEventValue(value: std.json.Value) bool {
    return switch (value) {
        .null, .bool, .integer, .float => true,
        .string => |text| text.len <= 4096,
        else => false,
    };
}

fn validateReliableEvents(events: std.json.Array, cursor: u64) !void {
    var previous: u64 = 0;
    for (events.items) |event| {
        if (event != .object) return error.InvalidEvent;
        const seq_value = event.object.get("seq") orelse return error.MissingEventSeq;
        if (seq_value != .integer or seq_value.integer <= 0) return error.InvalidEventSeq;
        const seq: u64 = @intCast(seq_value.integer);
        if (seq <= previous) return error.NonMonotonicEventSeq;
        if (seq > cursor) return error.EventSeqAfterCursor;
        previous = seq;

        const component = event.object.get("component") orelse return error.MissingEventComponent;
        if (component != .string or !validComponentId(component.string)) return error.InvalidEventComponent;
        const kind = event.object.get("kind") orelse return error.MissingEventKind;
        if (kind != .string or
            (!std.mem.eql(u8, kind.string, "click") and
                !std.mem.eql(u8, kind.string, "change") and
                !std.mem.eql(u8, kind.string, "submit"))) return error.InvalidEventKind;
        const event_value = event.object.get("value") orelse return error.MissingEventValue;
        if (!validEventValue(event_value)) return error.InvalidEventValue;
        const timestamp = event.object.get("ts") orelse return error.MissingEventTimestamp;
        if (timestamp != .integer or timestamp.integer < 0) return error.InvalidEventTimestamp;
    }
}

pub const ReplyMeta = struct {
    uncertain_delivery: bool = false,
    pre_delivery: bool = false,
    pre_delivery_code: PreDeliveryCode = .none,
};

pub const PreDeliveryCode = enum {
    none,
    no_compatible_gui,
};

pub fn validateReply(allocator: std.mem.Allocator, op: Op, json: []const u8) !ReplyMeta {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return error.ReplyNotObject;
    const ok = value.object.get("ok") orelse return error.MissingOk;
    if (ok != .bool) return error.InvalidOk;
    if (!ok.bool) {
        const message = value.object.get("error") orelse return error.MissingError;
        if (message != .string or message.string.len == 0) return error.InvalidError;
        const failure_class = value.object.get("failure_class") orelse return .{};
        if (failure_class != .string) return error.InvalidFailureClass;
        const uncertain = std.mem.eql(u8, failure_class.string, "uncertain_delivery");
        const pre_delivery = std.mem.eql(u8, failure_class.string, "pre_delivery");
        if (!uncertain and !pre_delivery) return error.InvalidFailureClass;
        const may_apply = value.object.get("mutation_may_have_applied") orelse
            return error.MissingMutationMayHaveApplied;
        if (may_apply != .bool) return error.InvalidMutationMayHaveApplied;
        const resend_safe = value.object.get("resend_safe") orelse return error.MissingResendSafe;
        if (resend_safe != .bool) return error.InvalidResendSafe;
        if (uncertain) {
            if (!may_apply.bool) return error.InvalidMutationMayHaveApplied;
            if (resend_safe.bool) return error.InvalidResendSafe;
            return .{ .uncertain_delivery = true };
        }
        // Only `pre_delivery` is left: any other class was rejected above.
        if (may_apply.bool) return error.InvalidMutationMayHaveApplied;
        if (!resend_safe.bool) return error.InvalidResendSafe;
        const code: PreDeliveryCode = if (value.object.get("error_code")) |error_code| blk: {
            if (error_code != .string) return error.InvalidErrorCode;
            break :blk std.meta.stringToEnum(PreDeliveryCode, error_code.string) orelse .none;
        } else .none;
        return .{ .pre_delivery = true, .pre_delivery_code = code };
    }
    if (value.object.get("failure_class") != null) return error.UnexpectedFailureClass;

    switch (op) {
        .show => {
            if (!positiveInteger(value.object.get("panel_id"))) return error.InvalidPanelId;
            try optionalEventEpoch(value.object);
        },
        .get => {
            const document = value.object.get("document") orelse return error.MissingDocument;
            if (document != .string or document.string.len == 0) return error.InvalidDocument;
            try optionalEventEpoch(value.object);
        },
        .events => {
            const events = value.object.get("events") orelse return error.MissingEvents;
            if (events != .array) return error.InvalidEvents;
            const dropped = value.object.get("dropped") orelse return error.MissingDropped;
            if (dropped != .integer or dropped.integer < 0) return error.InvalidDropped;
        },
        .reliable_events => {
            const events = value.object.get("events") orelse return error.MissingEvents;
            if (events != .array) return error.InvalidEvents;
            try requiredEventEpoch(value.object.get("event_epoch") orelse return error.MissingEventEpoch);
            const cursor = value.object.get("cursor") orelse return error.MissingCursor;
            if (cursor != .integer or cursor.integer < 0) return error.InvalidCursor;
            try validateReliableEvents(events.array, @intCast(cursor.integer));
            const dropped = value.object.get("dropped_total") orelse return error.MissingDroppedTotal;
            if (dropped != .integer or dropped.integer < 0) return error.InvalidDroppedTotal;
        },
        .list => {
            const panels = value.object.get("panels") orelse return error.MissingPanels;
            if (panels != .array) return error.InvalidPanels;
            for (panels.array.items) |panel| {
                if (panel != .object) return error.InvalidPanels;
                try optionalEventEpoch(panel.object);
            }
        },
        .open_session => {
            const session = value.object.get("session") orelse return error.MissingSession;
            if (session != .string or session.string.len < 1 or session.string.len > wire.MAX_SESSION_NAME)
                return error.InvalidSession;
            try requiredEventEpoch(value.object.get("origin_id") orelse return error.MissingOriginId);
            if (!positiveInteger(value.object.get("tab"))) return error.InvalidTab;
            if (!positiveInteger(value.object.get("pane"))) return error.InvalidPane;
        },
        .patch, .close, .unknown => {},
    }
    return .{};
}

test "panel RPC replies require a boolean status and operation results" {
    const t = std.testing;
    const a = t.allocator;
    try t.expect(!(try validateReply(a, .show, "{\"ok\":true,\"panel_id\":7}")).uncertain_delivery);
    try t.expect(!(try validateReply(a, .list, "{\"ok\":true,\"panels\":[]}")).uncertain_delivery);
    try t.expect(!(try validateReply(a, .events, "{\"ok\":true,\"events\":[],\"dropped\":0}")).uncertain_delivery);
    try t.expect(!(try validateReply(a, .reliable_events, "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":7,\"dropped_total\":2}")).uncertain_delivery);
    try t.expect(!(try validateReply(a, .get, "{\"ok\":true,\"document\":\"{}\"}")).uncertain_delivery);
    try t.expect(!(try validateReply(a, .close, "{\"ok\":false,\"error\":\"gone\"}")).uncertain_delivery);
    try t.expect((try validateReply(a, .show, "{\"ok\":false,\"error\":\"timed out\",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":false}")).uncertain_delivery);
    try t.expect((try validateReply(a, .show, "{\"ok\":false,\"error\":\"oom\",\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true}")).pre_delivery);
    try t.expectEqual(PreDeliveryCode.no_compatible_gui, (try validateReply(a, .show, "{\"ok\":false,\"error\":\"none\",\"error_code\":\"no_compatible_gui\",\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true}")).pre_delivery_code);
    try t.expectEqual(PreDeliveryCode.none, (try validateReply(a, .show, "{\"ok\":false,\"error\":\"gone\",\"error_code\":\"unrecognized_future_code\",\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true}")).pre_delivery_code);

    try t.expectError(error.ReplyNotObject, validateReply(a, .show, "[]"));
    try t.expectError(error.ReplyNotObject, validateReply(a, .show, "true"));
    try t.expectError(error.MissingOk, validateReply(a, .show, "{}"));
    try t.expectError(error.InvalidOk, validateReply(a, .show, "{\"ok\":1}"));
    try t.expectError(error.InvalidPanelId, validateReply(a, .show, "{\"ok\":true,\"panel_id\":0}"));
    try t.expectError(error.InvalidPanelId, validateReply(a, .show, "{\"ok\":true}"));
    try t.expectError(error.MissingError, validateReply(a, .show, "{\"ok\":false}"));
    try t.expectError(error.InvalidError, validateReply(a, .show, "{\"ok\":false,\"error\":\"\"}"));
    try t.expectError(error.InvalidError, validateReply(a, .show, "{\"ok\":false,\"error\":9}"));
    try t.expectError(error.InvalidFailureClass, validateReply(a, .show, "{\"ok\":false,\"error\":\"x\",\"failure_class\":\"maybe\"}"));
    try t.expectError(error.MissingMutationMayHaveApplied, validateReply(a, .show, "{\"ok\":false,\"error\":\"x\",\"failure_class\":\"uncertain_delivery\"}"));
    try t.expectError(error.InvalidResendSafe, validateReply(a, .show, "{\"ok\":false,\"error\":\"x\",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":true}"));
    try t.expectError(error.UnexpectedFailureClass, validateReply(a, .show, "{\"ok\":true,\"panel_id\":1,\"failure_class\":\"uncertain_delivery\"}"));
    try t.expectError(error.InvalidErrorCode, validateReply(a, .show, "{\"ok\":false,\"error\":\"x\",\"error_code\":7,\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true}"));
    try t.expectError(error.MissingPanels, validateReply(a, .list, "{\"ok\":true}"));
    try t.expectError(error.InvalidEvents, validateReply(a, .events, "{\"ok\":true,\"events\":{},\"dropped\":0}"));
    try t.expectError(error.MissingCursor, validateReply(a, .reliable_events, "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"dropped_total\":0}"));
    try t.expectError(error.MissingDocument, validateReply(a, .get, "{\"ok\":true}"));
}

test "panel open-session request accepts only exact relay-derived authority fields" {
    const t = std.testing;
    const good =
        "{\"cmd\":\"panel-open-session\",\"mux_session\":\"target\",\"mux_origin_id\":\"10000000000000000000000000000001\",\"request_token\":\"a1b2c3\"}";
    var parsed = try parseOpenSessionRequest(t.allocator, good);
    defer parsed.deinit();
    try t.expectEqualStrings("target", parsed.value.mux_session);
    try t.expectEqualStrings("10000000000000000000000000000001", parsed.value.mux_origin_id);
    try t.expectEqualStrings("a1b2c3", parsed.value.request_token);

    for ([_][]const u8{
        "\"host\":\"attacker\"",
        "\"socket\":\"/tmp/attacker\"",
        "\"command\":\"evil\"",
        "\"takeover\":true",
    }) |field| {
        const hostile = try std.fmt.allocPrint(
            t.allocator,
            "{{\"cmd\":\"panel-open-session\",\"mux_session\":\"target\",\"mux_origin_id\":\"10000000000000000000000000000001\",\"request_token\":\"a1b2c3\",{s}}}",
            .{field},
        );
        defer t.allocator.free(hostile);
        try t.expectError(error.UnexpectedField, parseOpenSessionRequest(t.allocator, hostile));
    }
    try t.expectError(error.InvalidSession, parseOpenSessionRequest(
        t.allocator,
        "{\"cmd\":\"panel-open-session\",\"mux_session\":\"\",\"mux_origin_id\":\"10000000000000000000000000000001\",\"request_token\":\"a1b2c3\"}",
    ));
    try t.expectError(error.InvalidOriginId, parseOpenSessionRequest(
        t.allocator,
        "{\"cmd\":\"panel-open-session\",\"mux_session\":\"target\",\"mux_origin_id\":\"bad\",\"request_token\":\"a1b2c3\"}",
    ));
    try t.expectError(error.UnexpectedField, parseOpenSessionRequest(
        t.allocator,
        "{\"cmd\":\"panel-open-session\",\"mux_session\":\"target\",\"mux_origin_id\":\"10000000000000000000000000000001\"}",
    ));
    try t.expectError(error.InvalidRequestToken, parseOpenSessionRequest(
        t.allocator,
        "{\"cmd\":\"panel-open-session\",\"mux_session\":\"target\",\"mux_origin_id\":\"10000000000000000000000000000001\",\"request_token\":\"bad token\"}",
    ));
}

test "panel open-session and reliable replies validate lifetime identities" {
    const t = std.testing;
    const a = t.allocator;
    _ = try validateReply(a, .open_session, "{\"ok\":true,\"session\":\"target\",\"origin_id\":\"10000000000000000000000000000001\",\"tab\":2,\"pane\":3}");
    try t.expectError(error.InvalidEventEpoch, validateReply(a, .open_session, "{\"ok\":true,\"session\":\"target\",\"origin_id\":\"BAD\",\"tab\":2,\"pane\":3}"));
    try t.expectError(error.MissingEventEpoch, validateReply(a, .reliable_events, "{\"ok\":true,\"events\":[],\"cursor\":0,\"dropped_total\":0}"));
}

test "reliable event requests bind acknowledgements to the live epoch" {
    const epoch = "10000000000000000000000000000001";
    try validateReliableEventsRequest(0, null, epoch);
    try validateReliableEventsRequest(0, "", epoch);
    try validateReliableEventsRequest(0, epoch, epoch);
    try validateReliableEventsRequest(9, epoch, epoch);
    try std.testing.expectError(error.MissingEventEpoch, validateReliableEventsRequest(1, null, epoch));
    try std.testing.expectError(error.InvalidEventEpoch, validateReliableEventsRequest(1, "bad", epoch));
    try std.testing.expectError(
        error.EventEpochMismatch,
        validateReliableEventsRequest(1, "20000000000000000000000000000002", epoch),
    );
}

test "reliable reply validates every event field and sequence bound" {
    const t = std.testing;
    const a = t.allocator;
    const prefix = "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"cursor\":2,\"dropped_total\":0,\"events\":";
    const good = prefix ++ "[{\"seq\":1,\"component\":\"query\",\"kind\":\"submit\",\"value\":\"draft\",\"ts\":1},{\"seq\":2,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":2}]}";
    _ = try validateReply(a, .reliable_events, good);

    const Case = struct { json: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .json = prefix ++ "[1]}", .err = error.InvalidEvent },
        .{ .json = prefix ++ "[{\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":1}]}", .err = error.MissingEventSeq },
        .{ .json = prefix ++ "[{\"seq\":0,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":1}]}", .err = error.InvalidEventSeq },
        .{ .json = prefix ++ "[{\"seq\":2,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":1},{\"seq\":1,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":2}]}", .err = error.NonMonotonicEventSeq },
        .{ .json = prefix ++ "[{\"seq\":3,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":1}]}", .err = error.EventSeqAfterCursor },
        .{ .json = prefix ++ "[{\"seq\":1,\"component\":\"bad id\",\"kind\":\"click\",\"value\":null,\"ts\":1}]}", .err = error.InvalidEventComponent },
        .{ .json = prefix ++ "[{\"seq\":1,\"component\":\"ok\",\"kind\":\"hover\",\"value\":null,\"ts\":1}]}", .err = error.InvalidEventKind },
        .{ .json = prefix ++ "[{\"seq\":1,\"component\":\"ok\",\"kind\":\"click\",\"value\":{},\"ts\":1}]}", .err = error.InvalidEventValue },
        .{ .json = prefix ++ "[{\"seq\":1,\"component\":\"ok\",\"kind\":\"click\",\"value\":null,\"ts\":-1}]}", .err = error.InvalidEventTimestamp },
    };
    for (cases) |case| try t.expectError(case.err, validateReply(a, .reliable_events, case.json));
}

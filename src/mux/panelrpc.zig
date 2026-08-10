//! Structural validation for panel presenter requests and replies.

const std = @import("std");

pub const Op = enum {
    show,
    patch,
    get,
    events,
    list,
    close,
    unknown,
};

pub fn opFromCommand(command: []const u8) Op {
    if (std.mem.eql(u8, command, "panel-show")) return .show;
    if (std.mem.eql(u8, command, "panel-patch")) return .patch;
    if (std.mem.eql(u8, command, "panel-get")) return .get;
    if (std.mem.eql(u8, command, "panel-events")) return .events;
    if (std.mem.eql(u8, command, "panel-list")) return .list;
    if (std.mem.eql(u8, command, "panel-close")) return .close;
    return .unknown;
}

fn positiveInteger(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .integer and v.integer > 0;
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
        .show => if (!positiveInteger(value.object.get("panel_id"))) return error.InvalidPanelId,
        .get => {
            const document = value.object.get("document") orelse return error.MissingDocument;
            if (document != .string or document.string.len == 0) return error.InvalidDocument;
        },
        .events => {
            const events = value.object.get("events") orelse return error.MissingEvents;
            if (events != .array) return error.InvalidEvents;
            const dropped = value.object.get("dropped") orelse return error.MissingDropped;
            if (dropped != .integer or dropped.integer < 0) return error.InvalidDropped;
        },
        .list => {
            const panels = value.object.get("panels") orelse return error.MissingPanels;
            if (panels != .array) return error.InvalidPanels;
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
    try t.expectError(error.MissingDocument, validateReply(a, .get, "{\"ok\":true}"));
}

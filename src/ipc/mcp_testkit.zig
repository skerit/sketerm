//! Test doubles shared by the MCP modules' unit tests: a scripted GUI
//! backend and an environment snapshot. Referenced only from tests.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const Backend = mcp.Backend;
const DirectTalkFailure = mcp.DirectTalkFailure;
const DirectTalkResult = mcp.DirectTalkResult;

pub const FakeBackend = struct {
    /// Scripted responses, consumed in order; the request lines are
    /// recorded for assertions.
    responses: []const []const u8,
    requests: std.ArrayList([]u8) = .empty,
    timeouts: std.ArrayList(i64) = .empty,
    /// Optional fake time consumed by each deadline-aware exchange.
    talk_delays_ms: []const i64 = &.{},
    /// Optional direct-transport failures aligned with `responses`.
    talk_failures: []const ?DirectTalkFailure = &.{},
    idx: usize = 0,
    clock_ms: i64 = 0,
    /// False scripts a server with no GUI socket.
    gui_attached: bool = true,
    allocator: std.mem.Allocator,

    pub fn talk(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        try self.requests.append(self.allocator, try self.allocator.dupe(u8, line));
        if (self.idx >= self.responses.len) return error.NoResponse;
        const r = self.responses[self.idx];
        self.idx += 1;
        return allocator.dupe(u8, r);
    }

    pub fn talkFor(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8, timeout_ms: i64) DirectTalkResult {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        const call_index = self.timeouts.items.len;
        self.timeouts.append(self.allocator, timeout_ms) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        if (call_index < self.talk_delays_ms.len)
            self.clock_ms += self.talk_delays_ms[call_index];
        const recorded = self.allocator.dupe(u8, line) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        self.requests.append(self.allocator, recorded) catch {
            self.allocator.free(recorded);
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        };
        if (self.idx < self.talk_failures.len) {
            if (self.talk_failures[self.idx]) |failure| {
                self.idx += 1;
                return .{ .failure = failure };
            }
        }
        if (self.idx >= self.responses.len)
            return .{ .failure = .{ .err = error.NoResponse, .delivery = .pre_delivery } };
        const response = self.responses[self.idx];
        self.idx += 1;
        const owned = allocator.dupe(u8, response) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .uncertain_delivery } };
        return .{ .reply = owned };
    }

    pub fn sleepMs(ctx: *anyopaque, ms: u32) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.clock_ms += ms;
    }

    pub fn nowMs(ctx: *anyopaque) i64 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.clock_ms;
    }

    pub fn backend(self: *FakeBackend) Backend {
        return .{
            .ctx = @ptrCast(self),
            .talk = talk,
            .talkFor = talkFor,
            .sleepMs = sleepMs,
            .nowMs = nowMs,
            .gui_attached = self.gui_attached,
        };
    }

    pub fn deinit(self: *FakeBackend) void {
        for (self.requests.items) |r| self.allocator.free(r);
        self.requests.deinit(self.allocator);
        self.timeouts.deinit(self.allocator);
    }
};

pub fn parseTestValue(a: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
}

/// One environment variable saved, cleared and put back, without an
/// allocator (a test helper must not perturb `std.testing.allocator`'s
/// leak accounting). A value longer than the buffer is refused rather
/// than truncated: silently restoring a different value is worse than
/// failing the test that clobbered it.
pub const EnvSave = struct {
    name: [*:0]const u8 = "",
    buf: [512]u8 = undefined,
    had: bool = false,

    pub fn take(self: *EnvSave, name: [*:0]const u8) !void {
        self.* = .{ .name = name };
        if (c.getenv(name)) |raw| {
            const value = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
            if (value.len >= self.buf.len) return error.EnvValueTooLong;
            @memcpy(self.buf[0..value.len], value);
            self.buf[value.len] = 0;
            self.had = true;
        }
        _ = c.unsetenv(name);
    }

    pub fn restore(self: *EnvSave) void {
        if (self.name[0] == 0) return;
        if (self.had) {
            _ = c.setenv(self.name, @ptrCast(&self.buf), 1);
        } else {
            _ = c.unsetenv(self.name);
        }
    }
};

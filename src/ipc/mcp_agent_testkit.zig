//! Test doubles shared by the `agent_*` unit tests of mcp_agent*.zig: a
//! tool rig on an isolated instance and a scripted Claude Code on a fake
//! daemon. Referenced only from tests.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const termdrive = @import("termdrive.zig");
const wire = @import("../mux/wire.zig");
const pathz = @import("../util/pathz.zig");

const mcp_agent = @import("mcp_agent.zig");

const Tool = mcp_agent.Tool;
const state = &mcp_agent.state;
const configure = mcp_agent.configure;
const shutdown = mcp_agent.shutdown;
const agentTool = mcp_agent.agentTool;

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;

pub const live = "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on\r\n$";
pub const erase = "\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[G";

/// A configured instance in a temp dir, torn down by `deinit`.
pub const ToolRig = struct {
    dir: pathz.TempDir,
    sock_buf: [128]u8 = undefined,
    arena: std.heap.ArenaAllocator,

    pub fn init(self: *ToolRig) !void {
        self.dir = pathz.TempDir.make("mcp-agent") orelse return error.SkipZigTest;
        const sock = try std.fmt.bufPrint(&self.sock_buf, "{s}/mux.sock", .{self.dir.path()});
        configure(testing.allocator, self.dir.path(), sock, false, null);
        // Never the user's real index or daemon.
        if (state.index_dir) |d| testing.allocator.free(d);
        state.index_dir = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{self.dir.path()});
        if (state.user_sock) |u| testing.allocator.free(u);
        state.user_sock = try std.fmt.allocPrint(testing.allocator, "{s}/user.sock", .{self.dir.path()});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    pub fn deinit(self: *ToolRig) void {
        shutdown();
        self.arena.deinit();
        self.dir.remove();
    }

    pub fn call(self: *ToolRig, tool: Tool, json: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const args = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        return agentTool(a, tool, args);
    }
};

pub fn expectError(arena: std.mem.Allocator, tool: []const u8, result: []const u8, code: []const u8) !void {
    const parsed = try mcp.expectToolResultShape(arena, tool, result);
    const err = parsed.object.get("structuredContent").?.object.get("error") orelse return error.ExpectedError;
    try testing.expectEqualStrings(code, err.object.get("code").?.string);
}

const fake_daemon = @import("launch_cleanup_test.zig");

const APP_BUSY = "\x1b]0;\xe2\x97\x90 Working\x07";
pub const APP_IDLE = "\x1b]0;\xe2\x9c\xb3 Claude Code\x07";
const APP_END = "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ APP_IDLE ++ erase ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ live;
const APP_PERMISSION = erase ++ "tool: Bash (rm notes.md)\r\nPermission Required: Bash command\r\n> rm notes.md\r\n" ++
    "Do you want to proceed?\r\n1. Yes\r\n2. No\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:\x07";

/// A Claude-Code-shaped app behind a fake daemon: a real Term over a
/// socketpair whose peer turns the input the adapter types into the
/// screen events the app would draw, so every agent tool runs its real
/// path (plans, waits, records) without a daemon or an app.
pub const FakeApp = struct {
    daemon: fake_daemon.Harness,
    parser: Parser,
    writer: wire.Writer,
    count: u32 = 0,
    /// The mirror's seq after the attach snapshot.
    seq: u64 = 7,
    typed: std.ArrayList(u8) = .empty,
    /// A slow turn is under way: the next line is queued behind it.
    slow: bool = false,
    /// A glacial turn is under way: lines are held in the queue (as
    /// previews) until an Escape throws them away with the turn.
    held: std.ArrayList([]u8) = .empty,
    holding: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(self: *FakeApp) !*termdrive.Term {
        self.* = .{
            .daemon = try fake_daemon.Harness.init(testing.allocator),
            .parser = Parser.init(testing.allocator),
            .writer = wire.Writer.init(testing.allocator),
        };
        const payload = try fake_daemon.snapshotPayloadSized(testing.allocator, false, 80, 24);
        defer testing.allocator.free(payload);
        try self.daemon.queueSnapshot(payload);
        var conn = self.daemon.takePrimary(testing.allocator);
        var origin: wire.SessionOriginId = undefined;
        @memcpy(&origin, fake_daemon.ORIGIN_ID);
        return termdrive.Term.attachConn(testing.allocator, &conn, "fake-claude", origin);
    }

    pub fn start(self: *FakeApp) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *FakeApp) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.typed.deinit(testing.allocator);
        for (self.held.items) |h| testing.allocator.free(h);
        self.held.deinit(testing.allocator);
        self.writer.deinit();
        self.parser.deinit();
        self.daemon.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *FakeApp = @ptrCast(@alignCast(user.?));
        var e = ev;
        defer e.deinit(testing.allocator);
        self.writer.putEvent(ev) catch return self.failed.store(true, .release);
        self.count += 1;
    }

    /// Draw `bytes` on the app's screen: one events frame.
    pub fn draw(self: *FakeApp, bytes: []const u8) !void {
        self.writer.buf.clearRetainingCapacity();
        self.count = 0;
        self.parser.advance(bytes, emit, @ptrCast(self));
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(testing.allocator);
        var head: [12]u8 = undefined;
        std.mem.writeInt(u64, head[0..8], self.seq, .little);
        std.mem.writeInt(u32, head[8..12], self.count, .little);
        try payload.appendSlice(testing.allocator, &head);
        try payload.appendSlice(testing.allocator, self.writer.buf.items);
        try self.daemon.queueEvents(payload.items);
        self.seq += self.count;
    }

    fn run(self: *FakeApp) void {
        var picker = false;
        var choice: u8 = 0;
        while (!self.stop.load(.acquire)) {
            const f = self.daemon.primary_peer.recvExpectFor(&.{.input}, 50) catch continue;
            defer f.deinit(testing.allocator);
            for (f.payload) |b| {
                if (picker) {
                    switch (b) {
                        '1'...'9' => choice = b - '0',
                        // Session only: applied a moment later, as Claude Code does.
                        's' => {
                            picker = false;
                            _ = c.usleep(400_000);
                            self.draw(if (choice == 1) MODEL_SET_SONNET else MODEL_SET_HAIKU) catch self.failed.store(true, .release);
                        },
                        else => {},
                    }
                    continue;
                }
                switch (b) {
                    '\r' => {
                        picker = std.mem.eql(u8, self.typed.items, "/model");
                        self.respond(self.typed.items) catch self.failed.store(true, .release);
                        self.typed.clearRetainingCapacity();
                    },
                    0x1b => {
                        self.typed.clearRetainingCapacity();
                        if (self.holding) self.interruptHeld() catch self.failed.store(true, .release);
                    },
                    else => self.typed.append(testing.allocator, b) catch self.failed.store(true, .release),
                }
            }
        }
    }

    /// Erase the live region and the queue previews above it.
    fn erasePreviews(self: *FakeApp, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(testing.allocator, erase);
        if (self.held.items.len > 0) for (0..self.held.items.len + 1) |_| try out.appendSlice(testing.allocator, "\x1b[1A\x1b[2K");
        try out.appendSlice(testing.allocator, "\x1b[G");
    }

    /// Claude Code's Escape: the turn ends and its queue is thrown away.
    fn interruptHeld(self: *FakeApp) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try self.erasePreviews(&out);
        try out.appendSlice(testing.allocator, "Interrupted \xc2\xb7 What should Claude do instead?\r\n" ++ live ++ APP_END);
        for (self.held.items) |h| testing.allocator.free(h);
        self.held.clearRetainingCapacity();
        self.holding = false;
        try self.draw(out.items);
    }

    /// What the app draws for a submitted line.
    fn respond(self: *FakeApp, line: []const u8) !void {
        var buf: [512]u8 = undefined;
        if (self.holding) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            try self.erasePreviews(&out);
            try self.held.append(testing.allocator, try testing.allocator.dupe(u8, line));
            for (self.held.items) |h| try out.print(testing.allocator, "you: {s}\r\n", .{h});
            try out.appendSlice(testing.allocator, "ctrl+enter to send now\r\n" ++ live);
            return self.draw(out.items);
        }
        if (self.slow) {
            // Typed while working: queued (a preview above the status
            // block), then taken at the turn's end as Claude Code 2.1.287
            // draws it.
            self.slow = false;
            try self.draw(try std.fmt.bufPrint(&buf, erase ++ "you: {s}\r\nctrl+enter to send now\r\n" ++ live, .{line}));
            _ = c.usleep(300_000);
            try self.draw("\x1b]133;C\x07\x1b]133;D\x07\x07" ++ APP_IDLE);
            try self.draw(try std.fmt.bufPrint(&buf, "\x1b[2K\x1b[1A" ** 5 ++ "\x1b[2K\x1b[G" ++ "Churned for 2s \xc2\xb7 done\r\nyou: {s}\r\n" ++ live ++ "\x1b]133;A\x07" ++ APP_BUSY, .{line}));
            try self.draw(try std.fmt.bufPrint(&buf, erase ++ "claude: echo: {s}\r\n" ++ live, .{line}));
            return self.draw(APP_END);
        }
        if (std.mem.eql(u8, line, "2")) {
            try self.draw("\r\x1b[5A\x1b[Jclaude: permission answered No\r\n" ++ live);
            return self.draw(APP_END);
        }
        if (std.mem.eql(u8, line, "/model")) return self.draw("\x1b]133;A\x07" ++ erase ++ "you: /model\r\n" ++ MODEL_PICKER);
        try self.draw(try std.fmt.bufPrint(&buf, "\x1b]133;A\x07" ++ APP_BUSY ++ erase ++ "you: {s}\r\n" ++ live, .{line}));
        if (std.mem.indexOf(u8, line, "permission") != null) return self.draw(APP_PERMISSION);
        if (std.mem.indexOf(u8, line, "slow") != null) {
            self.slow = true;
            return self.draw(erase ++ "claude: started the slow one\r\n" ++ live);
        }
        if (std.mem.indexOf(u8, line, "glacial") != null) {
            self.holding = true;
            return self.draw(erase ++ "claude: started the glacial one\r\n" ++ live);
        }
        try self.draw(try std.fmt.bufPrint(&buf, erase ++ "claude: echo: {s}\r\n" ++ live, .{line}));
        return self.draw(APP_END);
    }
};

const MODEL_PICKER = "Select model\r\n1. Sonnet 4.5\r\n2. Haiku 4.5 (selected)\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:";
const MODEL_SET = "\r\x1b[3A\x1b[JSet model to {s} for this session only\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07";
const MODEL_SET_HAIKU = std.fmt.comptimePrint(MODEL_SET, .{"Haiku 4.5"});
const MODEL_SET_SONNET = std.fmt.comptimePrint(MODEL_SET, .{"Sonnet 4.5"});

pub fn shaped(arena: std.mem.Allocator, tool: []const u8, result: []const u8) !std.json.ObjectMap {
    const parsed = try mcp.expectToolResultShape(arena, tool, result);
    const sc = parsed.object.get("structuredContent").?.object;
    if (sc.get("error")) |err| {
        std.debug.print("{s}: {s}\n", .{ tool, err.object.get("message").?.string });
        return error.UnexpectedToolError;
    }
    return sc;
}

//! VT500 escape-sequence state machine.
//!
//! Implements the canonical Paul Williams parser:
//!     https://vt100.net/emu/dec_ansi_parser
//!
//! The parser is stateful but allocation-free in the steady-state
//! path. OSC payloads accumulate into `osc_buf`, which is duplicated
//! into a heap slice on dispatch (transferred to the consumer).
//!
//! UTF-8 reassembly is *not* the parser's job — Print events carry
//! raw bytes and the consumer assembles codepoints (see
//! `util/utf8.zig`). This keeps the parser ASCII-bytewise simple.

const std = @import("std");
const Event = @import("event.zig").Event;

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    apc_string,
    sos_pm_string,
};

pub const EmitFn = *const fn (ctx: ?*anyopaque, ev: Event) void;

pub const Parser = struct {
    state: State = .ground,
    csi: Event.Csi = .{},
    cur_param: u32 = 0,
    has_cur_param: bool = false,
    osc_buf: std.ArrayList(u8) = .{},
    dcs_proto: Event.Dcs = .{},
    allocator: std.mem.Allocator,

    /// Hard cap on osc_buf growth; refusing further bytes once
    /// exceeded. 16 MiB is comfortably above the largest kitty
    /// graphics transmission a sane app would ever emit, and below
    /// "OOM the parser" territory.
    pub const osc_max: usize = 16 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.osc_buf.deinit(self.allocator);
    }

    /// Feed bytes. `emit` is called on the worker thread for each
    /// event produced.
    pub fn advance(
        self: *Parser,
        bytes: []const u8,
        emit: EmitFn,
        ctx: ?*anyopaque,
    ) void {
        for (bytes) |b| self.byte(b, emit, ctx);
    }

    fn byte(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        // "Anywhere" transitions per Williams (priority over current state).
        switch (b) {
            0x18, 0x1A => {
                emit(ctx, .{ .execute = b });
                self.transitionTo(.ground);
                return;
            },
            0x1B => {
                // In string-collection states, ESC begins the 7-bit
                // ST (`ESC \`). The string body must be dispatched
                // first; let those state handlers see the ESC.
                switch (self.state) {
                    .osc_string, .apc_string, .dcs_passthrough, .sos_pm_string => {},
                    else => {
                        self.enterEscape();
                        return;
                    },
                }
            },
            else => {},
        }

        switch (self.state) {
            .ground => self.byteGround(b, emit, ctx),
            .escape => self.byteEscape(b, emit, ctx),
            .escape_intermediate => self.byteEscapeIntermediate(b, emit, ctx),
            .csi_entry, .csi_param, .csi_intermediate, .csi_ignore => self.byteCsi(b, emit, ctx),
            .dcs_entry, .dcs_param, .dcs_intermediate, .dcs_passthrough, .dcs_ignore => self.byteDcs(b, emit, ctx),
            .osc_string => self.byteOsc(b, emit, ctx),
            .apc_string => self.byteApc(b, emit, ctx),
            .sos_pm_string => self.byteSosPm(b, emit, ctx),
        }
    }

    // ── State entry helpers ──────────────────────────────────────

    fn enterEscape(self: *Parser) void {
        self.csi = .{};
        self.cur_param = 0;
        self.has_cur_param = false;
        self.transitionTo(.escape);
    }

    fn enterCsiEntry(self: *Parser) void {
        self.csi = .{};
        self.cur_param = 0;
        self.has_cur_param = false;
        self.transitionTo(.csi_entry);
    }

    fn enterDcsEntry(self: *Parser) void {
        self.dcs_proto = .{};
        self.cur_param = 0;
        self.has_cur_param = false;
        self.osc_buf.clearRetainingCapacity();
        self.transitionTo(.dcs_entry);
    }

    fn dispatchDcs(self: *Parser, emit: EmitFn, ctx: ?*anyopaque) void {
        const body = self.allocator.dupe(u8, self.osc_buf.items) catch {
            return;
        };
        emit(ctx, .{ .dcs = .{ .proto = self.dcs_proto, .body = body } });
    }

    fn enterOscString(self: *Parser) void {
        self.osc_buf.clearRetainingCapacity();
        self.transitionTo(.osc_string);
    }

    fn enterApcString(self: *Parser) void {
        self.osc_buf.clearRetainingCapacity();
        self.transitionTo(.apc_string);
    }

    fn transitionTo(self: *Parser, new: State) void {
        self.state = new;
    }

    // ── Per-state byte handlers ──────────────────────────────────

    fn byteGround(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        _ = self;
        switch (b) {
            0x00...0x17, 0x19, 0x1C...0x1F => emit(ctx, .{ .execute = b }),
            // 0x20-0x7E printable ASCII
            // 0x7F DEL — execute per spec
            // 0x80-0xFF — UTF-8 continuation/leading; passed through
            //             as `print_byte`, main thread reassembles.
            0x7F => emit(ctx, .{ .execute = b }),
            else => emit(ctx, .{ .print_byte = b }),
        }
    }

    fn byteEscape(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (b) {
            0x00...0x17, 0x19, 0x1C...0x1F => emit(ctx, .{ .execute = b }),
            0x20...0x2F => {
                self.csi.intermediates[self.csi.n_intermediates] = b;
                if (self.csi.n_intermediates < 4) self.csi.n_intermediates += 1;
                self.transitionTo(.escape_intermediate);
            },
            0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E => {
                // ESC final dispatch, e.g. `ESC 7` = DECSC.
                emit(ctx, .{ .esc_final = .{
                    .intermediates = self.csi.intermediates,
                    .n_intermediates = self.csi.n_intermediates,
                    .final = b,
                } });
                self.transitionTo(.ground);
            },
            0x5B => self.enterCsiEntry(), // [
            0x5D => self.enterOscString(), // ]
            0x50 => self.enterDcsEntry(), // P
            0x5E => self.transitionTo(.sos_pm_string), // ^ PM
            0x5F => self.enterApcString(), // _ APC
            0x58 => self.transitionTo(.sos_pm_string), // X SOS
            0x7F => {}, // ignore
            else => self.transitionTo(.ground),
        }
    }

    fn byteEscapeIntermediate(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (b) {
            0x00...0x17, 0x19, 0x1C...0x1F => emit(ctx, .{ .execute = b }),
            0x20...0x2F => {
                if (self.csi.n_intermediates < 4) {
                    self.csi.intermediates[self.csi.n_intermediates] = b;
                    self.csi.n_intermediates += 1;
                }
            },
            0x30...0x7E => {
                emit(ctx, .{ .esc_final = .{
                    .intermediates = self.csi.intermediates,
                    .n_intermediates = self.csi.n_intermediates,
                    .final = b,
                } });
                self.transitionTo(.ground);
            },
            else => {},
        }
    }

    fn flushParam(self: *Parser) void {
        if (self.csi.n_params < 16) {
            self.csi.params[self.csi.n_params] = if (self.has_cur_param) self.cur_param else 0;
            self.csi.n_params += 1;
        }
        self.cur_param = 0;
        self.has_cur_param = false;
    }

    fn byteCsi(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (b) {
            0x00...0x17, 0x19, 0x1C...0x1F => emit(ctx, .{ .execute = b }),
            0x30...0x39 => {
                self.has_cur_param = true;
                self.cur_param = std.math.add(u32, self.cur_param *| 10, b - '0') catch std.math.maxInt(u32);
                self.transitionTo(.csi_param);
            },
            0x3A, 0x3B => {
                self.flushParam();
                self.transitionTo(.csi_param);
            },
            0x3C...0x3F => {
                if (self.state == .csi_entry) {
                    self.csi.private = b;
                    self.transitionTo(.csi_param);
                } else {
                    self.transitionTo(.csi_ignore);
                }
            },
            0x20...0x2F => {
                if (self.csi.n_intermediates < 4) {
                    self.csi.intermediates[self.csi.n_intermediates] = b;
                    self.csi.n_intermediates += 1;
                }
                self.transitionTo(.csi_intermediate);
            },
            0x40...0x7E => {
                if (self.has_cur_param) self.flushParam();
                if (self.state != .csi_ignore) {
                    self.csi.final = b;
                    emit(ctx, .{ .csi = self.csi });
                }
                self.transitionTo(.ground);
            },
            else => self.transitionTo(.csi_ignore),
        }
    }

    fn byteDcs(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (self.state) {
            .dcs_entry, .dcs_param, .dcs_intermediate => switch (b) {
                0x30...0x39 => {
                    self.has_cur_param = true;
                    self.cur_param = self.cur_param *| 10 +| (b - '0');
                    self.transitionTo(.dcs_param);
                },
                0x3A, 0x3B => {
                    if (self.dcs_proto.n_params < 16) {
                        self.dcs_proto.params[self.dcs_proto.n_params] = if (self.has_cur_param) self.cur_param else 0;
                        self.dcs_proto.n_params += 1;
                    }
                    self.cur_param = 0;
                    self.has_cur_param = false;
                    self.transitionTo(.dcs_param);
                },
                0x20...0x2F => {
                    if (self.dcs_proto.n_intermediates < 4) {
                        self.dcs_proto.intermediates[self.dcs_proto.n_intermediates] = b;
                        self.dcs_proto.n_intermediates += 1;
                    }
                    self.transitionTo(.dcs_intermediate);
                },
                0x40...0x7E => {
                    if (self.has_cur_param and self.dcs_proto.n_params < 16) {
                        self.dcs_proto.params[self.dcs_proto.n_params] = self.cur_param;
                        self.dcs_proto.n_params += 1;
                    }
                    self.dcs_proto.final = b;
                    // Body accumulates in osc_buf; full Event.dcs is
                    // emitted on terminator from dispatchDcs().
                    self.osc_buf.clearRetainingCapacity();
                    self.transitionTo(.dcs_passthrough);
                },
                else => self.transitionTo(.dcs_ignore),
            },
            .dcs_passthrough => {
                if (b == 0x07 or b == 0x9C) {
                    self.dispatchDcs(emit, ctx);
                    self.transitionTo(.ground);
                } else if (b == 0x1B) {
                    self.dispatchDcs(emit, ctx);
                    self.transitionTo(.escape);
                } else {
                    if (self.osc_buf.items.len < osc_max) self.osc_buf.append(self.allocator, b) catch {};
                }
            },
            .dcs_ignore => {
                if (b == 0x07 or b == 0x9C) self.transitionTo(.ground);
            },
            else => unreachable,
        }
    }

    fn byteOsc(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (b) {
            0x07, 0x9C => self.dispatchOsc(emit, ctx),
            0x1B => {
                // 7-bit ST: dispatch then enter escape state to
                // consume the trailing '\'.
                self.dispatchOsc(emit, ctx);
                self.transitionTo(.escape);
            },
            else => if (self.osc_buf.items.len < osc_max) self.osc_buf.append(self.allocator, b) catch {},
        }
    }

    fn byteApc(self: *Parser, b: u8, emit: EmitFn, ctx: ?*anyopaque) void {
        switch (b) {
            0x07, 0x9C => self.dispatchApc(emit, ctx),
            0x1B => {
                self.dispatchApc(emit, ctx);
                self.transitionTo(.escape);
            },
            else => if (self.osc_buf.items.len < osc_max) self.osc_buf.append(self.allocator, b) catch {},
        }
    }

    fn byteSosPm(self: *Parser, b: u8, _: EmitFn, _: ?*anyopaque) void {
        // SOS / PM: no payload exposed in v1.
        switch (b) {
            0x07, 0x9C => self.transitionTo(.ground),
            0x1B => self.transitionTo(.escape),
            else => {},
        }
    }

    fn dispatchOsc(self: *Parser, emit: EmitFn, ctx: ?*anyopaque) void {
        const bytes = self.allocator.dupe(u8, self.osc_buf.items) catch {
            self.transitionTo(.ground);
            return;
        };
        emit(ctx, .{ .osc = .{ .bytes = bytes } });
        self.transitionTo(.ground);
    }

    fn dispatchApc(self: *Parser, emit: EmitFn, ctx: ?*anyopaque) void {
        const bytes = self.allocator.dupe(u8, self.osc_buf.items) catch {
            self.transitionTo(.ground);
            return;
        };
        emit(ctx, .{ .apc = .{ .bytes = bytes } });
        self.transitionTo(.ground);
    }
};

// ── Tests ────────────────────────────────────────────────────────

const TestCollector = struct {
    events: std.ArrayList(Event) = .{},
    allocator: std.mem.Allocator,

    fn deinit(self: *TestCollector) void {
        for (self.events.items) |*ev| ev.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn emit(ctx: ?*anyopaque, ev: Event) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        self.events.append(self.allocator, ev) catch {};
    }
};

test "ground prints" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("Hi", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 2), col.events.items.len);
    try std.testing.expectEqual(@as(u8, 'H'), col.events.items[0].print_byte);
    try std.testing.expectEqual(@as(u8, 'i'), col.events.items[1].print_byte);
}

test "execute cr/lf" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\r\n", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 2), col.events.items.len);
    try std.testing.expectEqual(@as(u8, '\r'), col.events.items[0].execute);
    try std.testing.expectEqual(@as(u8, '\n'), col.events.items[1].execute);
}

test "csi cup" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b[10;20H", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 1), col.events.items.len);
    const csi = col.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'H'), csi.final);
    try std.testing.expectEqual(@as(u8, 2), csi.n_params);
    try std.testing.expectEqual(@as(u32, 10), csi.params[0]);
    try std.testing.expectEqual(@as(u32, 20), csi.params[1]);
}

test "csi sgr complex" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b[1;38;2;255;128;0m", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 1), col.events.items.len);
    const csi = col.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'm'), csi.final);
    try std.testing.expectEqual(@as(u8, 6), csi.n_params);
    try std.testing.expectEqual(@as(u32, 1), csi.params[0]);
    try std.testing.expectEqual(@as(u32, 38), csi.params[1]);
    try std.testing.expectEqual(@as(u32, 2), csi.params[2]);
    try std.testing.expectEqual(@as(u32, 255), csi.params[3]);
    try std.testing.expectEqual(@as(u32, 128), csi.params[4]);
    try std.testing.expectEqual(@as(u32, 0), csi.params[5]);
}

test "csi private decset" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b[?1049h", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 1), col.events.items.len);
    const csi = col.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'h'), csi.final);
    try std.testing.expectEqual(@as(u8, '?'), csi.private);
    try std.testing.expectEqual(@as(u32, 1049), csi.params[0]);
}

test "osc title bel-terminated" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b]0;hello\x07", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 1), col.events.items.len);
    try std.testing.expectEqualStrings("0;hello", col.events.items[0].osc.bytes);
}

test "esc final decsc" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b7", TestCollector.emit, &col);
    try std.testing.expectEqual(@as(usize, 1), col.events.items.len);
    try std.testing.expectEqual(@as(u8, '7'), col.events.items[0].esc_final.final);
}

test "cancel via can/sub" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b[10;\x18A", TestCollector.emit, &col);
    // CAN (0x18) should cancel the in-progress CSI; 'A' is then ground print.
    try std.testing.expect(col.events.items.len >= 2);
    var saw_print_a = false;
    for (col.events.items) |ev| switch (ev) {
        .print_byte => |b| if (b == 'A') { saw_print_a = true; },
        else => {},
    };
    try std.testing.expect(saw_print_a);
}

test "DCS body collected and dispatched on ST" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    // ESC P q ABC ESC \\
    p.advance("\x1bPq" ++ "ABC" ++ "\x1b\\", TestCollector.emit, &col);
    var saw_dcs = false;
    for (col.events.items) |ev| switch (ev) {
        .dcs => |d| {
            try std.testing.expectEqual(@as(u8, 'q'), d.proto.final);
            try std.testing.expectEqualStrings("ABC", d.body);
            saw_dcs = true;
        },
        else => {},
    };
    try std.testing.expect(saw_dcs);
}

test "OSC dispatches on BEL terminator" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b]52;c;SGVsbG8=\x07", TestCollector.emit, &col);
    var saw_osc = false;
    for (col.events.items) |ev| switch (ev) {
        .osc => |o| {
            try std.testing.expectEqualStrings("52;c;SGVsbG8=", o.bytes);
            saw_osc = true;
        },
        else => {},
    };
    try std.testing.expect(saw_osc);
}

test "OSC dispatches on ESC backslash terminator" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b]0;sketerm\x1b\\", TestCollector.emit, &col);
    var saw_osc = false;
    for (col.events.items) |ev| switch (ev) {
        .osc => |o| {
            try std.testing.expectEqualStrings("0;sketerm", o.bytes);
            saw_osc = true;
        },
        else => {},
    };
    try std.testing.expect(saw_osc);
}

test "APC kitty graphics dispatched on ESC \\\\" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b_Ga=T,f=32,s=1,v=1,i=1;ABCD\x1b\\", TestCollector.emit, &col);
    var saw_apc = false;
    for (col.events.items) |ev| switch (ev) {
        .apc => |a| {
            try std.testing.expect(std.mem.startsWith(u8, a.bytes, "Ga="));
            saw_apc = true;
        },
        else => {},
    };
    try std.testing.expect(saw_apc);
}

test "ESC mid-CSI cancels and starts new sequence" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    // CSI partial → ESC → CUP — the partial CSI should be discarded.
    p.advance("\x1b[12;\x1b[1;1H", TestCollector.emit, &col);
    var cup_count: u32 = 0;
    for (col.events.items) |ev| switch (ev) {
        .csi => |c| if (c.final == 'H') {
            cup_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 1), cup_count);
}

test "colon-separated SGR (38:2:r:g:b)" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    // Modern truecolor with colons: should parse exactly like
    // semicolon-separated.
    p.advance("\x1b[38:2:255:128:0m", TestCollector.emit, &col);
    var found = false;
    for (col.events.items) |ev| switch (ev) {
        .csi => |c| if (c.final == 'm' and c.n_params >= 5) {
            try std.testing.expectEqual(@as(u32, 38), c.params[0]);
            try std.testing.expectEqual(@as(u32, 2), c.params[1]);
            try std.testing.expectEqual(@as(u32, 255), c.params[2]);
            try std.testing.expectEqual(@as(u32, 128), c.params[3]);
            try std.testing.expectEqual(@as(u32, 0), c.params[4]);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

test "DECRQM (CSI ? 1 \\$ p) parses with intermediate" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var col = TestCollector{ .allocator = std.testing.allocator };
    defer col.deinit();
    p.advance("\x1b[?1$p", TestCollector.emit, &col);
    var found = false;
    for (col.events.items) |ev| switch (ev) {
        .csi => |c| if (c.private == '?' and c.final == 'p' and
            c.n_intermediates == 1 and c.intermediates[0] == '$')
        {
            try std.testing.expectEqual(@as(u32, 1), c.params[0]);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

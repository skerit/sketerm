//! Events emitted by the VT parser to the main-thread consumer.
//!
//! Parser runs on the worker thread. Events flow through the SPSC
//! ring (`util/ring.zig`) and are applied by the main thread to the
//! Screen / ImageStore / etc.
//!
//! Owned-payload events (`osc`, `apc`, `dcs_data`) carry heap slices
//! whose ownership transfers across threads. The consumer must free
//! them after processing.

const std = @import("std");

pub const Event = union(enum) {
    /// One Unicode codepoint to print (after UTF-8 reassembly on
    /// main thread; parser emits raw bytes via `print_byte`).
    print: u32,

    /// Raw byte from Ground state — main thread runs UTF-8 decoder
    /// (see `util/utf8.zig`) to assemble codepoints. Keeps the
    /// parser stateless wrt encoding.
    print_byte: u8,

    /// C0 control byte (0x00–0x1F minus ESC, plus DEL 0x7F).
    execute: u8,

    /// CSI dispatch (e.g. `ESC [ 1 ; 2 H`).
    csi: Csi,

    /// ESC final dispatch (e.g. `ESC 7` = DECSC).
    /// Repurposes the Csi struct's intermediates + final.
    esc_final: EscFinal,

    /// Operating-system command (`ESC ] ... ST`).
    osc: Osc,

    /// Application-program command (`ESC _ ... ST`) — Kitty graphics.
    apc: Osc,

    /// Device-control-string with full body collected.
    /// `body` is heap-owned by event; consumer frees.
    dcs: DcsFull,

    /// (Legacy markers, kept so existing switch arms compile.)
    dcs_start: Dcs,
    dcs_data: []u8,
    dcs_end: void,

    /// PTY reached EOF (child closed all references to the slave).
    child_eof: i32,

    pub const Csi = struct {
        params: [16]u32 = .{0} ** 16,
        n_params: u8 = 0,
        intermediates: [4]u8 = .{0} ** 4,
        n_intermediates: u8 = 0,
        /// Private parameter prefix: '?', '>', '=', '<', or 0.
        private: u8 = 0,
        /// Final byte (0x40–0x7E).
        final: u8 = 0,

        /// Get parameter `idx`, with `default` if absent or zero
        /// (matching xterm behavior: 0 means "use default").
        pub fn paramOrDefault(self: *const Csi, idx: usize, default: u32) u32 {
            if (idx >= self.n_params) return default;
            const p = self.params[idx];
            return if (p == 0) default else p;
        }

        /// Raw param without zero→default substitution.
        pub fn paramRaw(self: *const Csi, idx: usize) u32 {
            if (idx >= self.n_params) return 0;
            return self.params[idx];
        }
    };

    pub const EscFinal = struct {
        intermediates: [4]u8 = .{0} ** 4,
        n_intermediates: u8 = 0,
        final: u8 = 0,
    };

    pub const Osc = struct {
        bytes: []u8, // owned
    };

    pub const Dcs = struct {
        params: [16]u32 = .{0} ** 16,
        n_params: u8 = 0,
        intermediates: [4]u8 = .{0} ** 4,
        n_intermediates: u8 = 0,
        final: u8 = 0,
    };

    pub const DcsFull = struct {
        proto: Dcs,
        body: []u8, // owned
    };

    /// Free any heap-owned payload. Call after processing.
    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .osc, .apc => |o| allocator.free(o.bytes),
            .dcs_data => |b| allocator.free(b),
            .dcs => |d| allocator.free(d.body),
            else => {},
        }
    }
};

test "csi paramOrDefault uses default on zero" {
    var csi = Event.Csi{};
    csi.params[0] = 0;
    csi.params[1] = 5;
    csi.n_params = 2;
    try std.testing.expectEqual(@as(u32, 1), csi.paramOrDefault(0, 1));
    try std.testing.expectEqual(@as(u32, 5), csi.paramOrDefault(1, 1));
    try std.testing.expectEqual(@as(u32, 1), csi.paramOrDefault(2, 1));
}

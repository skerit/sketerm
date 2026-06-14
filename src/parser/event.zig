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

    /// Run of consecutive printable bytes (0x20..0x7E and 0x80+).
    /// Cuts the per-event overhead for the common "shell prints
    /// long line" path. Worker still emits this event but with a
    /// fixed-size payload (no heap), so SPSC ring stays simple.
    print_run: PrintRun,

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

    /// A recoverable parser error — e.g. a DCS/OSC/APC payload that
    /// overflowed the collection buffer and was truncated. Fixed-size
    /// (no heap), so it rides the SPSC ring and mux wire like any other
    /// event; the consumer decides what to do (we log it main-thread).
    parse_error: ParseError,

    /// Up to 64 printable bytes accumulated by the parser. After
    /// shrinking Csi/Dcs, PrintRun is the union-size limiter at
    /// 65 bytes. Bumping to 128 was tried and showed no measurable
    /// throughput win while doubling Event size, so 64 stays.
    pub const PrintRun = struct {
        bytes: [64]u8 = .{0} ** 64,
        len: u8 = 0,
    };

    pub const Csi = struct {
        /// Per-param value, clamped to u16 max on flush. Real-world
        /// CSI params (SGR codes 0-255, cursor positions <screen-size,
        /// DECSET mode numbers ≤ 9999, truecolor RGB 0-255) all fit in
        /// u16 with margin. Saves 32 bytes vs the original [16]u32 —
        /// Csi 76 → 44 B, Event union 80 → 68 B.
        params: [16]u16 = .{0} ** 16,
        /// Bit i = 1 iff `params[i]` was reached via a `:` (sub-parameter
        /// of `params[i-1]`) rather than `;`. Used by the SGR handler
        /// to distinguish `4:3` (curly-underline sub-param) from `4;3`
        /// (underline AND italic). Bit 0 is always 0. Replaces the
        /// older `[16]bool` to shrink the event union (was 16 B, now 2).
        is_sub_bits: u16 = 0,
        n_params: u8 = 0,
        intermediates: [4]u8 = .{0} ** 4,
        n_intermediates: u8 = 0,
        /// Private parameter prefix: '?', '>', '=', '<', or 0.
        private: u8 = 0,
        /// Final byte (0x40–0x7E).
        final: u8 = 0,

        /// Get parameter `idx`, with `default` if absent or zero
        /// (matching xterm behavior: 0 means "use default"). Returns
        /// u32 for back-compat with consumers that arithmetic on it.
        pub fn paramOrDefault(self: *const Csi, idx: usize, default: u32) u32 {
            if (idx >= self.n_params) return default;
            const p: u32 = self.params[idx];
            return if (p == 0) default else p;
        }

        /// Raw param without zero→default substitution.
        pub fn paramRaw(self: *const Csi, idx: usize) u32 {
            if (idx >= self.n_params) return 0;
            return self.params[idx];
        }

        pub fn isSub(self: *const Csi, idx: usize) bool {
            if (idx >= 16) return false;
            return (self.is_sub_bits >> @intCast(idx)) & 1 == 1;
        }

        pub fn setSub(self: *Csi, idx: usize, v: bool) void {
            if (idx >= 16) return;
            const bit: u16 = @as(u16, 1) << @intCast(idx);
            if (v) {
                self.is_sub_bits |= bit;
            } else {
                self.is_sub_bits &= ~bit;
            }
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
        /// DCS params. 4 × u16 is enough for every DCS we route —
        /// XTGETTCAP / DECRQSS only inspect intermediates+final,
        /// sixel reads its own body. Shrinking from [16]u32 → [4]u16
        /// dropped DcsFull from 88 → 32 B and the whole Event union
        /// from 96 → 76 B (Csi is now the limiter).
        params: [4]u16 = .{0} ** 4,
        n_params: u8 = 0,
        intermediates: [4]u8 = .{0} ** 4,
        n_intermediates: u8 = 0,
        final: u8 = 0,
    };

    pub const DcsFull = struct {
        proto: Dcs,
        body: []u8, // owned
    };

    pub const ParseError = struct {
        kind: Kind,
        pub const Kind = enum(u8) {
            dcs_truncated,
            osc_truncated,
            apc_truncated,
        };
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

//! Module root for `sketerm-webengine`; the helper itself lives under
//! `src/web/`.
//!
//! The root file's DIRECTORY is the boundary a module's `@import`s may
//! not escape. Rooted at `src/web/main.zig`, no helper file could reach
//! `src/util/` at all — which is how the helper grew private copies of
//! `mkdir -p` and of the atomic-write dance that already existed there,
//! and why `zpool` had to be mapped in under a name. Rooting the module
//! at `src/` removes that pressure; nothing else about the helper
//! changes, and the CEF containment rule is still "CEF types stay in
//! src/web", which is about what this binary links, not about what it
//! may import.

pub const main = @import("web/main.zig").main;

/// No per-thread alternate signal stack: std's 256 KiB default is a STATIC
/// TLS block, and glibc carves static TLS out of every thread's stack, so any
/// engine thread asking for a small stack failed to start. V8's sampling
/// profiler thread (64 KiB) did, and its CHECK killed the renderer at
/// `Profiler.start` (measured: TLS segment 0x40018 bytes, renderer SIGTRAP).
pub const std_options: @import("std").Options = blk: {
    var o: @import("std").Options = .{};
    if (@hasField(@import("std").Options, "signal_stack_size")) o.signal_stack_size = null;
    break :blk o;
};

test {
    _ = @import("web/cefhost.zig");
    _ = @import("web/cefhost/semlayer.zig");
    _ = @import("web/cefhost/intercept.zig");
    _ = @import("web/cefhost/downloads.zig");
    _ = @import("web/cefhost/untrusted.zig");
    _ = @import("web/cefhost/emulation.zig");
    _ = @import("web/cefhost/dragdrop.zig");
}

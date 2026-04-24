//! Unit-test entry point.
//!
//! Imports every module that contains `test` blocks so
//! `zig build test` discovers them.

const std = @import("std");

comptime {
    _ = @import("util/ring.zig");
    _ = @import("util/utf8.zig");
    _ = @import("parser/event.zig");
    _ = @import("parser/vt.zig");
}

test {
    std.testing.refAllDecls(@This());
}

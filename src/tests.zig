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
    _ = @import("grid/cell.zig");
    _ = @import("grid/style_pool.zig");
    _ = @import("grid/screen.zig");
}

test {
    std.testing.refAllDecls(@This());
}

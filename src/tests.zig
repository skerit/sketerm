// Unit-test entry point. Imports every module that contains
// `test` blocks so `zig build test` discovers them.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

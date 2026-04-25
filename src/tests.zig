//! Unit-test entry point.
//!
//! Imports every module that contains `test` blocks so
//! `zig build test` discovers them.

const std = @import("std");

comptime {
    _ = @import("util/ring.zig");
    _ = @import("util/utf8.zig");
    _ = @import("util/percent.zig");
    _ = @import("parser/event.zig");
    _ = @import("parser/vt.zig");
    _ = @import("parser/conformance_test.zig");
    _ = @import("parser/screen_conformance_test.zig");
    _ = @import("parser/wezterm_conformance_test.zig");
    _ = @import("grid/cell.zig");
    _ = @import("grid/style_pool.zig");
    _ = @import("grid/screen.zig");
    _ = @import("grid/selection.zig");
    _ = @import("grid/selection_conformance_test.zig");
    _ = @import("grid/image_store.zig");
    _ = @import("layout.zig");
    _ = @import("layout_simple.zig");
    _ = @import("parser/sixel.zig");
    _ = @import("parser/iterm_image.zig");
    _ = @import("parser/kitty_image.zig");
    _ = @import("ui/input.zig");
    _ = @import("ui/input_conformance_test.zig");
    _ = @import("parser/multicell_conformance_test.zig");
    _ = @import("parser/clipboard_conformance_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}

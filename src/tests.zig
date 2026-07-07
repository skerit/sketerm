//! Unit-test entry point.
//!
//! Imports every module that contains `test` blocks so
//! `zig build test` discovers them.

const std = @import("std");

comptime {
    _ = @import("util/ring.zig");
    _ = @import("util/utf8.zig");
    _ = @import("util/percent.zig");
    _ = @import("util/pathz.zig");
    _ = @import("util/shellquote.zig");
    _ = @import("util/humantype.zig");
    _ = @import("util/platform.zig");
    _ = @import("util/png.zig");
    _ = @import("util/churn.zig");
    _ = @import("util/content.zig");
    _ = @import("util/yuv.zig");
    _ = @import("shim_drift_test.zig");
    _ = @import("mux/predict.zig");
    _ = @import("mux/kitty_inline.zig");
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
    _ = @import("grid/reflow.zig");
    _ = @import("grid/reflow_screen_test.zig");
    _ = @import("grid/url_scan.zig");
    _ = @import("grid/word_motion.zig");
    _ = @import("layout.zig");
    _ = @import("shader_preset.zig");
    _ = @import("layout_simple.zig");
    _ = @import("parser/sixel.zig");
    _ = @import("parser/iterm_image.zig");
    _ = @import("parser/kitty_image.zig");
    _ = @import("ui/input.zig");
    _ = @import("ui/tree.zig");
    _ = @import("ui/hints.zig");
    _ = @import("ui/pane.zig");
    _ = @import("ui/tab_effects.zig");
    _ = @import("a11y/view.zig");
    _ = @import("a11y/nsax.zig");
    _ = @import("ipc/protocol.zig");
    _ = @import("ipc/mux_cli.zig");
    _ = @import("ipc/keys.zig");
    _ = @import("ipc/mcp.zig");
    _ = @import("render/bg_pass.zig");
    _ = @import("mux/wire.zig");
    _ = @import("mux/snapshot.zig");
    _ = @import("mux/rudp.zig");
    _ = @import("render/atlas_test.zig");
    _ = @import("render/atlas.zig");
    _ = @import("render/cell_pass.zig");
    _ = @import("render/style.zig");
    _ = @import("ui/input_conformance_test.zig");
    _ = @import("parser/multicell_conformance_test.zig");
    _ = @import("parser/clipboard_conformance_test.zig");
    _ = @import("parser/graphics_conformance_test.zig");
    _ = @import("config.zig");
    _ = @import("remoteapp.zig");
    _ = @import("grid/kitty_images.zig");
    _ = @import("grid/kitty_placeholder.zig");
    _ = @import("grid/image_pipeline_test.zig");
    _ = @import("grid/bidi.zig");
    _ = @import("grid/schemes.zig");
    _ = @import("wlhost/wire.zig");
    _ = @import("wlhost/protocol.zig");
    _ = @import("wlhost/track.zig");
    _ = @import("wlhost/pipe.zig");
    _ = @import("wlhost/compositor.zig");
    _ = @import("wlhost/zpool.zig");
    _ = @import("wlhost/pixcodec.zig");
    _ = @import("wlhost/vcodec.zig");
    _ = @import("winstream/proto.zig");
    _ = @import("winstream/source.zig");
    _ = @import("winstream/keymap.zig");
    _ = @import("remote_window.zig");
}

test {
    std.testing.refAllDecls(@This());
}

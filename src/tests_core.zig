//! GTK-free unit-test entry point -- `zig build test-core`.
//!
//! `src/tests.zig` pulls the GUI in, so on a host without a new enough
//! GTK the ENTIRE suite is unrunnable, daemon logic included. This root
//! imports only modules that compile against the lean `configureCoreDeps`
//! set (libc, no GTK/GLib), which is the same dependency graph
//! `sketerm-mux` itself is built with.
//!
//! It is a SUBSET, not a replacement: `zig build test` remains the full
//! suite. Adding a module here that reaches GTK breaks `mux-portable`
//! users, so the rule is the same one the daemon follows -- if it
//! imports anything under `ui/` or `render/`, it does not belong here.

const std = @import("std");

comptime {
    _ = @import("config.zig");
    _ = @import("filebrowser/cache.zig");
    _ = @import("filebrowser/colkeys.zig");
    _ = @import("filebrowser/clipboard.zig");
    _ = @import("filebrowser/crumbs.zig");
    _ = @import("filebrowser/desktop.zig");
    _ = @import("filebrowser/emblems.zig");
    _ = @import("filebrowser/entry.zig");
    _ = @import("filebrowser/incomplete.zig");
    _ = @import("filebrowser/fileicon.zig");
    _ = @import("filebrowser/format.zig");
    _ = @import("filebrowser/grouping.zig");
    _ = @import("filebrowser/hexdump.zig");
    _ = @import("filebrowser/model.zig");
    _ = @import("filebrowser/paths.zig");
    _ = @import("filebrowser/places.zig");
    _ = @import("filebrowser/previewers.zig");
    _ = @import("filebrowser/progress.zig");
    _ = @import("filebrowser/query.zig");
    _ = @import("filebrowser/registers.zig");
    _ = @import("filebrowser/thumbs.zig");
    _ = @import("filebrowser/snapshots.zig");
    _ = @import("filebrowser/viewmem.zig");
    _ = @import("filebrowser/xferqueue.zig");
    _ = @import("fsmount.zig");
    _ = @import("grid/bidi.zig");
    _ = @import("grid/cell.zig");
    _ = @import("grid/image_pipeline_test.zig");
    _ = @import("grid/image_store.zig");
    _ = @import("grid/kitty_images.zig");
    _ = @import("grid/kitty_placeholder.zig");
    _ = @import("grid/reflow.zig");
    _ = @import("grid/reflow_screen_test.zig");
    _ = @import("grid/schemes.zig");
    _ = @import("grid/screen.zig");
    _ = @import("grid/selection.zig");
    _ = @import("grid/selection_conformance_test.zig");
    _ = @import("grid/style_pool.zig");
    _ = @import("grid/url_scan.zig");
    _ = @import("grid/word_motion.zig");
    _ = @import("ipc/cdp.zig");
    _ = @import("ipc/evkeys.zig");
    _ = @import("ipc/fsdrive.zig");
    _ = @import("ipc/fstransfer.zig");
    _ = @import("ipc/keys.zig");
    _ = @import("ipc/mcpassets.zig");
    _ = @import("ipc/mux_cli.zig");
    _ = @import("ipc/protocol.zig");
    _ = @import("ipc/termdrive.zig");
    _ = @import("ipc/xkblayout.zig");
    _ = @import("layout.zig");
    _ = @import("layout_simple.zig");
    _ = @import("mux/a11yhub.zig");
    _ = @import("mux/cast.zig");
    _ = @import("mux/dbus.zig");
    _ = @import("mux/desktop.zig");
    _ = @import("mux/deploy.zig");
    _ = @import("mux/display.zig");
    _ = @import("mux/dmabuf_egl.zig");
    _ = @import("mux/drmdev.zig");
    _ = @import("mux/fsjob.zig");
    _ = @import("mux/fsjournal.zig");
    _ = @import("mux/fsserve.zig");
    _ = @import("mux/icons.zig");
    _ = @import("mux/keep.zig");
    _ = @import("mux/kitty_inline.zig");
    _ = @import("mux/log.zig");
    _ = @import("mux/logring.zig");
    _ = @import("mux/mediameta.zig");
    _ = @import("mux/mediameta_test.zig");
    _ = @import("mux/opuscodec.zig");
    _ = @import("mux/predict.zig");
    _ = @import("mux/pulse.zig");
    _ = @import("mux/client.zig");
    _ = @import("mux/punch.zig");
    _ = @import("mux/rudp.zig");
    _ = @import("mux/shell.zig");
    _ = @import("mux/snapshot.zig");
    _ = @import("mux/wavcap.zig");
    _ = @import("mux/wire.zig");
    _ = @import("parser/clipboard_conformance_test.zig");
    _ = @import("parser/conformance_test.zig");
    _ = @import("parser/event.zig");
    _ = @import("parser/graphics_conformance_test.zig");
    _ = @import("parser/iterm_image.zig");
    _ = @import("parser/kitty_image.zig");
    _ = @import("parser/multicell_conformance_test.zig");
    _ = @import("parser/screen_conformance_test.zig");
    _ = @import("parser/sixel.zig");
    _ = @import("parser/vt.zig");
    _ = @import("parser/wezterm_conformance_test.zig");
    _ = @import("remoteapp.zig");
    _ = @import("shader_preset.zig");
    _ = @import("shim_drift_test.zig");
    _ = @import("util/churn.zig");
    _ = @import("util/clock.zig");
    _ = @import("util/content.zig");
    _ = @import("util/crashlog.zig");
    _ = @import("util/filehash.zig");
    _ = @import("util/humantype.zig");
    _ = @import("util/imagecodec.zig");
    _ = @import("util/marks.zig");
    _ = @import("util/mounts.zig");
    _ = @import("util/ocr.zig");
    _ = @import("util/pathz.zig");
    _ = @import("util/pattern.zig");
    _ = @import("util/percent.zig");
    _ = @import("util/platform.zig");
    _ = @import("util/png.zig");
    _ = @import("util/shellintegration.zig");
    _ = @import("util/shellquote.zig");
    _ = @import("util/template.zig");
    _ = @import("util/utf8.zig");
    _ = @import("util/videorec.zig");
    _ = @import("util/webm.zig");
    _ = @import("util/yuv.zig");
    _ = @import("winstream/keymap.zig");
    _ = @import("winstream/proto.zig");
    _ = @import("winstream/source.zig");
    _ = @import("wlhost/compositor.zig");
    _ = @import("wlhost/dmabuf.zig");
    _ = @import("wlhost/pipe.zig");
    _ = @import("wlhost/pixcodec.zig");
    _ = @import("wlhost/protocol.zig");
    _ = @import("wlhost/track.zig");
    _ = @import("wlhost/vcodec.zig");
    _ = @import("wlhost/wire.zig");
    _ = @import("wlhost/zpool.zig");
}

test {
    std.testing.refAllDecls(@This());
}

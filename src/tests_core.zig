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
    _ = @import("editor/linebreak.zig");
    _ = @import("editor/diff.zig");
    _ = @import("editor/document.zig");
    _ = @import("editor/rope.zig");
    _ = @import("editor/fuzz.zig");
    _ = @import("editor/stress.zig");
    _ = @import("editor/journal.zig");
    _ = @import("editor/selection.zig");
    _ = @import("editor/reload.zig");
    _ = @import("editor/transaction.zig");
    _ = @import("editor/unicode.zig");
    _ = @import("editor/model.zig");
    _ = @import("editor/view_model.zig");
    _ = @import("editor/commands.zig");
    _ = @import("editor/search.zig");
    _ = @import("editor/regex.zig");
    _ = @import("editor/structure.zig");
    _ = @import("editor/project.zig");
    _ = @import("editor/gitdiff.zig");
    _ = @import("editor/psearch.zig");
    _ = @import("editor/syntax.zig");
    _ = @import("editor/outline.zig");
    _ = @import("editor/theme.zig");
    _ = @import("lsp/rpc.zig");
    _ = @import("lsp/semantic.zig");
    _ = @import("lsp/inlay.zig");
    _ = @import("lsp/position.zig");
    _ = @import("lsp/servers.zig");
    _ = @import("lsp/session.zig");
    _ = @import("lsp/session_test.zig");
    _ = @import("lsp/diagnostics.zig");
    _ = @import("lsp/docsync.zig");
    _ = @import("lsp/pending.zig");
    _ = @import("lsp/symbols.zig");
    _ = @import("lsp/proc.zig");
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
    _ = @import("filebrowser/gitstatus.zig");
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
    _ = @import("filebrowser/diskusage.zig");
    _ = @import("filebrowser/picker.zig");
    _ = @import("portal.zig");
    _ = @import("filebrowser/viewmem.zig");
    _ = @import("filebrowser/xferqueue.zig");
    _ = @import("fsmount.zig");
    _ = @import("grid/bidi.zig");
    _ = @import("grid/cell.zig");
    _ = @import("grid/image_pipeline_test.zig");
    _ = @import("grid/image_size.zig");
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
    _ = @import("grid/bracket.zig");
    _ = @import("ipc/evkeys.zig");
    _ = @import("ipc/fsdrive.zig");
    _ = @import("ipc/fstransfer.zig");
    _ = @import("ipc/keys.zig");
    _ = @import("mux/channel_pump.zig");
    _ = @import("ipc/socks5.zig");
    _ = @import("ipc/socksbridge.zig");
    _ = @import("ipc/mcpassets.zig");
    _ = @import("ipc/mcpfilter.zig");
    _ = @import("ipc/mcp_tools.zig");
    _ = @import("ipc/mcp_registry.zig");
    _ = @import("ipc/mux_cli.zig");
    _ = @import("ipc/panelstore.zig");
    _ = @import("ipc/paneldrive.zig");
    _ = @import("ipc/protocol.zig");
    _ = @import("ipc/termdrive.zig");
    _ = @import("ipc/webdrive.zig");
    _ = @import("ipc/webprofiles.zig");
    _ = @import("ipc/xkblayout.zig");
    // Enforced network policy: std-only decision half of the web
    // helper's request gate, shared with the GUI-side client.
    _ = @import("web/netpolicy.zig");
    _ = @import("web/route.zig");
    // ui/panel data layer: under ui/ by home. canary/doc/events are GTK-free by
    // contract; assets.zig is GTK-free by BUILD GATE — its gdk-pixbuf work sits
    // behind `comptime build_options.glib`, and the test that needs it returns
    // error.SkipZigTest in this root.
    // Toolkit-free UI models: the tab forest is generic over its Ref
    // and imports nothing but std, so it belongs in both roots.
    _ = @import("ui/tabforest.zig");
    _ = @import("ui/debounce.zig");
    _ = @import("ui/commandcat.zig");
    _ = @import("ui/panel/canary.zig");
    _ = @import("ui/panel/doc.zig");
    _ = @import("ui/panel/assets.zig");
    _ = @import("ui/panel/events.zig");
    _ = @import("layout.zig");
    _ = @import("layout_simple.zig");
    _ = @import("viewer.zig");
    _ = @import("editor_app.zig");
    _ = @import("web_app.zig");
    _ = @import("a11y/docview.zig");
    _ = @import("a11y/webproj.zig");
    _ = @import("a11y/detect.zig");
    _ = @import("mux/a11yhub.zig");
    _ = @import("mux/cast.zig");
    _ = @import("mux/cast_play.zig");
    _ = @import("mux/dbus.zig");
    _ = @import("mux/dbusconn.zig");
    _ = @import("mux/desktop.zig");
    _ = @import("mux/deploy.zig");
    _ = @import("mux/socks5_client.zig");
    _ = @import("mux/sshroute.zig");
    _ = @import("mux/display.zig");
    _ = @import("mux/dmabuf_egl.zig");
    _ = @import("mux/drmdev.zig");
    _ = @import("mux/disk_usage.zig");
    _ = @import("mux/fsjob.zig");
    _ = @import("mux/fs_boundary.zig");
    _ = @import("mux/fsjournal.zig");
    _ = @import("mux/fsserve.zig");
    _ = @import("mux/icons.zig");
    _ = @import("mux/keep.zig");
    _ = @import("mux/kitty_inline.zig");
    _ = @import("mux/daemon_cast.zig");
    _ = @import("mux/daemon_debug.zig");
    _ = @import("mux/daemon.zig");
    _ = @import("mux/daemon_fsjobs.zig");
    _ = @import("mux/daemon_native.zig");
    _ = @import("mux/daemon_serve.zig");
    _ = @import("mux/daemon_sessions.zig");
    _ = @import("mux/log.zig");
    _ = @import("mux/logring.zig");
    _ = @import("mux/mediameta.zig");
    _ = @import("mux/mediameta_test.zig");
    _ = @import("mux/opuscodec.zig");
    _ = @import("mux/panel_relay_test.zig");
    _ = @import("mux/panelrpc.zig");
    _ = @import("mux/predict.zig");
    _ = @import("mux/pulse.zig");
    _ = @import("mux/client.zig");
    _ = @import("mux/punch.zig");
    _ = @import("mux/rudp.zig");
    _ = @import("mux/shell.zig");
    _ = @import("mux/snapshot.zig");
    _ = @import("mux/wavcap.zig");
    _ = @import("mux/wire.zig");
    _ = @import("mux/webstore.zig");
    _ = @import("mux/xwayland.zig");
    _ = @import("parser/clipboard_conformance_test.zig");
    _ = @import("parser/conformance_test.zig");
    _ = @import("parser/event.zig");
    _ = @import("parser/graphics_conformance_test.zig");
    _ = @import("parser/iterm_image.zig");
    _ = @import("parser/kitty_image.zig");
    _ = @import("parser/multicell_conformance_test.zig");
    _ = @import("parser/screen_conformance_test.zig");
    _ = @import("parser/glyph_protocol.zig");
    _ = @import("grid/glyph_glossary.zig");
    _ = @import("parser/sixel.zig");
    _ = @import("parser/vt.zig");
    _ = @import("parser/wezterm_conformance_test.zig");
    _ = @import("remoteapp.zig");
    _ = @import("shader_preset.zig");
    _ = @import("shim_drift_test.zig");
    _ = @import("panelvocab.zig");
    _ = @import("panelvocab_drift_test.zig");
    _ = @import("util/churn.zig");
    _ = @import("util/clock.zig");
    _ = @import("util/env.zig");
    _ = @import("util/strz.zig");
    _ = @import("util/jsonnum.zig");
    _ = @import("util/spinlock.zig");
    // browser helper protocol + keymap: pure std, no CEF — the helper
    // itself is opt-in (`zig build web`) but its wire format and key
    // mapping are testable everywhere.
    _ = @import("web/protocol.zig");
    _ = @import("web/cefargs.zig");
    _ = @import("web/webkeys.zig");
    _ = @import("web/ozone.zig");
    _ = @import("web/keymap.zig");
    _ = @import("web/presenter.zig");
    _ = @import("web/semantic.zig");
    _ = @import("web/reader.zig");
    _ = @import("web/hints.zig");
    _ = @import("web/pace.zig");
    _ = @import("web/filter.zig");
    _ = @import("web/filtersub.zig");
    _ = @import("web/userscript.zig");
    _ = @import("web/urlhost.zig");
    _ = @import("web/model.zig");
    _ = @import("web/axtree.zig");
    _ = @import("web/semnav.zig");
    _ = @import("web/navfault.zig");
    _ = @import("web/loadretry.zig");
    _ = @import("web/watchgeom.zig");
    _ = @import("web/webpresence.zig");
    _ = @import("web/reader_guards.zig");
    _ = @import("web/quarantine.zig");
    // WebExtensions foundation: match patterns, MV2 manifest parse,
    // storage.local JSON, and the XPI/zip reader — all pure std.
    _ = @import("web/webext/match.zig");
    _ = @import("web/webext/manifest.zig");
    _ = @import("web/webext/storage.zig");
    _ = @import("web/webext/webrequest.zig");
    _ = @import("web/webext/zip.zig");
    _ = @import("web/webext/install.zig");
    _ = @import("web/webext/assets.zig");
    _ = @import("web/webext/origins.zig");
    _ = @import("web/webext/bgpage.zig");
    _ = @import("web/webext/i18n.zig");
    _ = @import("web/webext/tabs.zig");
    _ = @import("web/webext/action.zig");
    _ = @import("web/webext/registry.zig");
    _ = @import("web/webext/reply.zig");
    _ = @import("web/webext/host.zig");
    _ = @import("util/content.zig");
    _ = @import("util/crashlog.zig");
    _ = @import("util/filehash.zig");
    _ = @import("util/framing.zig");
    _ = @import("util/glob.zig");
    _ = @import("util/fdcancel.zig");
    _ = @import("util/humantype.zig");
    _ = @import("util/imagecodec.zig");
    _ = @import("util/markdown.zig");
    _ = @import("util/marks.zig");
    _ = @import("util/mounts.zig");
    _ = @import("util/ocr.zig");
    _ = @import("util/pathz.zig");
    _ = @import("util/readfile.zig");
    _ = @import("util/fdio.zig");
    _ = @import("util/b64.zig");
    _ = @import("util/invocation.zig");
    _ = @import("util/atomicwrite.zig");
    _ = @import("util/pattern.zig");
    _ = @import("util/percent.zig");
    _ = @import("util/suggest.zig");
    _ = @import("util/platform.zig");
    _ = @import("util/lifetime.zig");
    _ = @import("util/png.zig");
    _ = @import("util/shellintegration.zig");
    _ = @import("util/shellquote.zig");
    _ = @import("util/template.zig");
    _ = @import("util/titlefmt.zig");
    _ = @import("util/utf8.zig");
    _ = @import("util/videorec.zig");
    _ = @import("util/webm.zig");
    _ = @import("util/yuv.zig");
    _ = @import("winstream/keymap.zig");
    _ = @import("winstream/proto.zig");
    _ = @import("winstream/source.zig");
    _ = @import("wlhost/compositor.zig");
    _ = @import("wlhost/dmabuf.zig");
    _ = @import("wlhost/keymaps.zig");
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

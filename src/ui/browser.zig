//! File-browser pane face (phases 3+4 of docs/filebrowser-roadmap.md).
//!
//! This file is the package facade. The implementation lives in
//! src/ui/browser/, one module per responsibility; `view.zig` carries
//! the `BrowserView` struct plus an index naming the module that owns
//! each method. Start there.
//!
//! Async by construction: non-blocking mux connections watched via
//! g_unix_fd_add -- the GLib loop is NEVER blocked on a reply.
//! Listings are subscriptions (fs_op open_view): pushed fs_delta
//! frames keep every visible directory live, including tree-expanded
//! subdirectories (expanded set == watch set).

const paths = @import("../filebrowser/paths.zig");

pub const BrowserView = @import("browser/view.zig").BrowserView;
pub const HostAction = @import("browser/types.zig").HostAction;

/// Location specs are plain data, so the parser and the network-mount
/// bypass live GTK-free under src/filebrowser.
pub const Loc = paths.Loc;
pub const parseSpec = paths.parseSpec;
pub const formatSpec = paths.formatSpec;
pub const SPEC_BUF_LEN = paths.SPEC_BUF_LEN;
pub const BypassHit = paths.BypassHit;
pub const mountBypass = paths.mountBypass;

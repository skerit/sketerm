//! Canonical sketerm version, shared by the GUI, the mux daemon and
//! the MCP server so `sketerm doctor` can detect binary skew.
//!
//! The value comes from `build.zig.zon`'s `.version` via build.zig, so
//! bumping that one line moves every binary at once. Importing this
//! module therefore requires the target to carry a `build_options`
//! module.

const build_options = @import("build_options");

/// Sentinel-terminated because callers hand it straight to `fprintf`;
/// `addOption` emits a plain `[]const u8`, so the `:0` is re-attached
/// here (comptime-checked against the underlying string literal).
pub const string: [:0]const u8 = build_options.version[0..build_options.version.len :0];

/// The Model Context Protocol revision `sketerm mcp` implements, sent in
/// the `initialize` reply. This is a SPEC DATE, not our version: it must
/// change ONLY when the server is actually updated to a new MCP
/// revision, and never as part of a release bump.
pub const mcp_protocol = "2025-06-18";

// The two WIRE protocol versions deliberately live with the code whose
// rules govern them, not here: `mux/wire.zig` (PROTO_VERSION,
// MIN_SERVER_PROTO and friends) and `web/protocol.zig` (PROTO_VERSION).
// Both are append-only negotiated integers, and the number is only
// meaningful next to the frame table it describes -- moving it away
// from the tags is how it drifts.

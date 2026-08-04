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

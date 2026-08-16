//! Module root for `sketerm-webengine`; the helper itself lives under
//! `src/web/`.
//!
//! The root file's DIRECTORY is the boundary a module's `@import`s may
//! not escape. Rooted at `src/web/main.zig`, no helper file could reach
//! `src/util/` at all — which is how the helper grew private copies of
//! `mkdir -p` and of the atomic-write dance that already existed there,
//! and why `zpool` had to be mapped in under a name. Rooting the module
//! at `src/` removes that pressure; nothing else about the helper
//! changes, and the CEF containment rule is still "CEF types stay in
//! src/web", which is about what this binary links, not about what it
//! may import.

pub const main = @import("web/main.zig").main;

test {
    _ = @import("web/cefhost.zig");
}

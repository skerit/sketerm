//! Compile-only test root for every `-Dportable-target` (`zig build
//! mux-portable`): the OS-specific halves of these modules are analyzed for
//! the portable OS (macOS included) on a build host that cannot run them.
//! The cross-built binary runs on the target itself, e.g. a Mac.

comptime {
    _ = @import("util/platform.zig");
    _ = @import("ipc/agentsline.zig");
}

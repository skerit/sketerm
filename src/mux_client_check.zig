//! Standalone-compile guard for the public `mux-client` module: forces
//! analysis of every pub decl in the SDK surface against the CORE dep
//! set only, so a GUI/GLib reference sneaking into the client graph
//! fails `zig build mux-client-check` instead of a downstream consumer.

const std = @import("std");
const sdk = @import("mux-client");

comptime {
    std.testing.refAllDecls(sdk.wire);
    std.testing.refAllDecls(sdk.client);
    std.testing.refAllDecls(sdk.channel_pump);
    std.testing.refAllDecls(sdk.sockpath);
    std.testing.refAllDecls(sdk.snapshot);
    std.testing.refAllDecls(sdk.panelrpc);
    std.testing.refAllDecls(sdk.paneldoc);
}

pub fn main() void {}

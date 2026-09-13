//! The name every sketerm-mux process answers to, and the argv modes its one image serves.
//!
//! Self-spawn sites exec the literal `/proc/self/exe` (see `platform.selfExecPathZ`), and the
//! kernel names such a process after that string: argv[0] `/proc/self/exe`, comm `exe`. A
//! daemon holding a user's sessions was therefore invisible to `ps ax | grep sketerm` and to
//! `pgrep -x sketerm-mux`. Every self-exec passes `BINARY` as argv[0] and `mux_main` renames
//! the process to it at startup. `sketerm doctor` classifies processes with the same `Mode`
//! table the daemon dispatches its own argv on, so the two cannot drift.

const std = @import("std");

/// argv[0] and process name of every sketerm-mux image, whatever file it was exec'd from.
pub const BINARY = "sketerm-mux";

/// Daemon-mode flag selecting process isolation (one worker process per session).
pub const BROKER_FLAG = "--broker";

/// Option naming the daemon socket an invocation listens on or bridges to.
pub const SOCKET_FLAG = "--socket";

/// What one sketerm-mux invocation does, selected by its first mode argument.
pub const Mode = enum {
    daemon,
    proxy,
    job,
    keep,
    udp_listen,
    udp_connect,
    socks5_connect,
    display,

    /// The argv word selecting this mode; null for the flagless daemon.
    pub fn flag(self: Mode) ?[:0]const u8 {
        return switch (self) {
            .daemon => null,
            .proxy => "--proxy",
            .job => "--job",
            .keep => "--keep",
            .udp_listen => "--udp-listen",
            .udp_connect => "--udp-connect",
            .socks5_connect => "--internal-socks5-connect",
            .display => "display",
        };
    }

    /// Short operator-facing name, as `sketerm doctor` prints it.
    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .daemon => "daemon",
            .proxy => "ssh proxy",
            .job => "file job",
            .keep => "display keeper",
            .udp_listen => "udp listener",
            .udp_connect => "udp connector",
            .socks5_connect => "socks5 connector",
            .display => "display cli",
        };
    }

    /// True when `arg` is exactly this mode's flag.
    pub fn is(self: Mode, arg: []const u8) bool {
        const word = self.flag() orelse return false;
        return std.mem.eql(u8, arg, word);
    }
};

/// The mode of a full argv (argv[0] included): the first argument naming one, else `.daemon`.
/// An option value spelled like a mode word (`--socket --proxy`) is misread; mux_main
/// would consume it as the value.
pub fn modeOf(args: []const []const u8) Mode {
    if (args.len < 2) return .daemon;
    for (args[1..]) |arg| {
        for (std.enums.values(Mode)) |mode| {
            if (mode.is(arg)) return mode;
        }
    }
    return .daemon;
}

/// True for a file name a sketerm-mux image ships under: the binary itself, the portable
/// build, or a copy deployed to a remote host as `sketerm-mux-<sha256>`.
pub fn isBinaryName(base: []const u8) bool {
    return std.mem.eql(u8, base, BINARY) or std.mem.startsWith(u8, base, BINARY ++ "-");
}

const t = std.testing;

test "every mode but the daemon has a distinct flag that selects it" {
    for (std.enums.values(Mode)) |mode| {
        const word = mode.flag() orelse {
            try t.expectEqual(Mode.daemon, mode);
            continue;
        };
        try t.expectEqual(mode, modeOf(&.{ BINARY, word }));
        for (std.enums.values(Mode)) |other| {
            if (other != mode) try t.expect(!other.is(word));
        }
    }
}

test "modeOf skips leading options and defaults to the daemon" {
    try t.expectEqual(Mode.daemon, modeOf(&.{BINARY}));
    try t.expectEqual(Mode.daemon, modeOf(&.{}));
    try t.expectEqual(Mode.daemon, modeOf(&.{ BINARY, BROKER_FLAG, "--socket", "/tmp/x/mux.sock" }));
    try t.expectEqual(Mode.keep, modeOf(&.{ "/proc/self/exe", "--socket", "/x", "--keep" }));
    try t.expectEqual(Mode.display, modeOf(&.{ BINARY, "--socket", "/x", "display", "list" }));
    // argv[0] is never a mode, even when a file is named like one.
    try t.expectEqual(Mode.daemon, modeOf(&.{"--proxy"}));
}

test "isBinaryName accepts shipped and deployed names only" {
    try t.expect(isBinaryName("sketerm-mux"));
    try t.expect(isBinaryName("sketerm-mux-portable"));
    try t.expect(isBinaryName("sketerm-mux-0f3a9c"));
    try t.expect(!isBinaryName("sketerm"));
    try t.expect(!isBinaryName("sketerm-muxer"));
    try t.expect(!isBinaryName("exe"));
}

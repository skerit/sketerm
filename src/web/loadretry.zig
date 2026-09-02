//! The helper's one-shot reload after `ERR_NETWORK_CHANGED`.
//!
//! Chromium's Linux network-change notifier watches netlink and treats
//! ANY interface coming or going as an IP address change (a Docker
//! container starting adds a `veth` pair and touches a bridge, which is
//! enough) and then deliberately aborts every in-flight connection
//! with `ERR_NETWORK_CHANGED`, main-frame navigations included. CEF
//! exposes no way to widen the notifier's ignore list. The error means
//! "nothing about the request was wrong, the local stack blinked", so
//! the helper re-issues a main-frame load ONCE on exactly that code and
//! reports it as `ev_load_retry` (capability `load-retry`) instead of
//! `ev_load_error`. A second failure of the retried load is reported as
//! the ordinary error, whatever its code.
//!
//! Std-only; in both test roots. `cefhost.zig` asserts
//! `ERR_NETWORK_CHANGED` against the CEF binding.

const std = @import("std");

/// Chromium's `net::ERR_NETWORK_CHANGED`.
pub const ERR_NETWORK_CHANGED: i32 = -21;

/// Whether a main-frame load failure with this code is worth one retry.
/// Deliberately ONE code: every other net error describes the request
/// or the site, and retrying it would only hide a real failure.
pub fn retryable(code: i32) bool {
    return code == ERR_NETWORK_CHANGED;
}

/// Per-view retry budget. CEF fires `on_load_start` only for a COMMITTED
/// document (an error page is reported through `on_load_error` and never
/// starts a load), so a failing attempt produces no start of its own:
/// the retry's own start is what settles the budget, and the next start
/// after that (a link, a form, a redirect) is a new document with a
/// fresh budget. A client-requested navigation resets it outright.
pub const State = enum(u8) {
    idle,
    /// A retry was issued for the current navigation.
    issued,
    /// The retry's document started (or its load failed too): no more
    /// retries until the next document.
    settled,

    /// A main-frame load failed with a retryable code. True means the
    /// caller re-issues the load; false means it reports the error.
    pub fn arm(self: *State) bool {
        switch (self.*) {
            .idle => {
                self.* = .issued;
                return true;
            },
            .issued, .settled => {
                self.* = .settled;
                return false;
            },
        }
    }

    /// A main-frame document committed.
    pub fn loadStarted(self: *State) void {
        self.* = switch (self.*) {
            .issued => .settled,
            .settled, .idle => .idle,
        };
    }

    /// The client asked for a navigation: a fresh budget.
    pub fn reset(self: *State) void {
        self.* = .idle;
    }
};

test "only ERR_NETWORK_CHANGED is retryable" {
    try std.testing.expect(retryable(ERR_NETWORK_CHANGED));
    try std.testing.expect(!retryable(-3)); // ERR_ABORTED
    try std.testing.expect(!retryable(-105)); // ERR_NAME_NOT_RESOLVED
    try std.testing.expect(!retryable(0));
}

test "one retry per navigation, whether or not the retry commits" {
    var s: State = .idle;
    // navigate -> fails -> retried -> retry fails too -> reported.
    try std.testing.expect(s.arm());
    try std.testing.expect(!s.arm());
    try std.testing.expect(s == .settled);
    // A client navigation is a fresh budget.
    s.reset();
    try std.testing.expect(s.arm());
    // The retry commits; a later failure of THAT document (a reload the
    // page itself triggers, say) is still not retried a second time.
    s.loadStarted();
    try std.testing.expect(s == .settled);
    try std.testing.expect(!s.arm());
    // The next committed document (a link click) has its own budget.
    s.reset();
    try std.testing.expect(s.arm());
    s.loadStarted();
    s.loadStarted();
    try std.testing.expect(s == .idle);
    try std.testing.expect(s.arm());
}

test "a successful first load never spends the budget" {
    var s: State = .idle;
    s.loadStarted();
    try std.testing.expect(s == .idle);
    try std.testing.expect(s.arm());
}

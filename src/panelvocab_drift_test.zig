//! Drift guard for the panel wire vocabulary.
//!
//! The component-id rule, the payload bounds and the interaction-kind
//! set are a contract between the GUI panel layer and the daemon's
//! presenter validator. They used to be two hand-copied rules with two
//! bounds (`src/mux/panelrpc.zig` hardcoded 64 while `src/ui/panel/
//! doc.zig` read `events.MAX_ID`), so raising one side's limit would
//! have made the daemon accept ids the GUI rejects.
//!
//! Both now read `panelvocab.zig`. This module is what makes that
//! provable rather than a convention: it is the only place that imports
//! BOTH sides at once, and it fails the build if they ever disagree
//! again.

const std = @import("std");
const t = std.testing;

const vocab = @import("panelvocab.zig");
const doc = @import("ui/panel/doc.zig");
const events = @import("ui/panel/events.zig");
const panelrpc = @import("mux/panelrpc.zig");

test "GUI and daemon share one id bound" {
    try t.expectEqual(vocab.MAX_ID, doc.MAX_ID);
    try t.expectEqual(vocab.MAX_ID, events.MAX_ID);
    try t.expectEqual(vocab.MAX_ID, panelrpc.MAX_COMPONENT_ID);
}

test "GUI and daemon share one text bound" {
    try t.expectEqual(vocab.MAX_TEXT, doc.MAX_TEXT);
    try t.expectEqual(vocab.MAX_TEXT, events.MAX_TEXT);
    try t.expectEqual(vocab.MAX_TEXT, panelrpc.MAX_EVENT_TEXT);
    try t.expectEqual(vocab.MAX_SHORT_TEXT, events.MAX_SHORT_TEXT);
}

test "GUI and daemon answer identically on every id shape" {
    const max_id = "a" ** vocab.MAX_ID;
    const too_long = "a" ** (vocab.MAX_ID + 1);
    const ids = [_][]const u8{
        "",       "a",     "_",       "9",      "ok.button-2",
        "A_b.c-D9", max_id, too_long,  "-lead",  ".lead",
        "9lead",  "a/b",   "a b",     "a:b",    "a\x00b",
        "a\nb",   "caf\xc3\xa9",      "\xff",   "--",
    };
    for (ids) |id| {
        try t.expectEqual(vocab.validId(id), doc.validId(id));
        try t.expectEqual(vocab.validId(id), panelrpc.validComponentId(id));
    }
}

test "GUI and daemon share one interaction-kind set" {
    // Every kind the GUI can queue must be a kind the daemon accepts,
    // and the reverse: one enum, one token spelling.
    inline for (@typeInfo(events.Kind).@"enum".fields) |f| {
        try t.expect(panelrpc.validEventKind(f.name));
        try t.expectEqual(@field(vocab.Kind, f.name), vocab.kindFromName(f.name).?);
    }
    try t.expect(!panelrpc.validEventKind("hover"));
    try t.expect(!panelrpc.validEventKind(""));
}

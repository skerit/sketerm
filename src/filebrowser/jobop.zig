//! What kind of work a daemon job is, from the wire verb that started
//! it. The transfers strip and the status line phrase a job by this,
//! and it decides whether the job's `done`/`total` are bytes or items.

const std = @import("std");

pub const JobOp = enum {
    copy,
    move,
    trash,
    restore,
    delete,
    /// A search, live query, flat view or panelize stream: it fills a
    /// tab of its own and never belongs in the transfers strip.
    query,
    other,

    /// Classify a wire verb. `delete_src` is the cross_copy move flag;
    /// the plain `copy` verb never moves (a same-host move is a rename,
    /// not a job).
    pub fn fromWire(op: []const u8, delete_src: bool) JobOp {
        if (std.mem.eql(u8, op, "copy") or std.mem.eql(u8, op, "cross_copy"))
            return if (delete_src) .move else .copy;
        if (std.mem.eql(u8, op, "trash")) return .trash;
        if (std.mem.eql(u8, op, "trash_restore")) return .restore;
        if (std.mem.eql(u8, op, "delete_tree") or std.mem.eql(u8, op, "secure_delete") or
            std.mem.eql(u8, op, "delete")) return .delete;
        if (std.mem.eql(u8, op, "find") or std.mem.eql(u8, op, "grep") or
            std.mem.eql(u8, op, "panelize") or std.mem.eql(u8, op, "flat")) return .query;
        return .other;
    }

    /// Whether the job's `done`/`total` counters are bytes (a copy or
    /// move) rather than entries handled (trash, delete, restore).
    pub fn countsBytes(self: JobOp) bool {
        return self == .copy or self == .move;
    }

    /// Whether the job shows in the ambient transfers strip at all.
    pub fn inStrip(self: JobOp) bool {
        return self != .query;
    }

    /// The present-tense verb for a running job of this kind.
    pub fn activeVerb(self: JobOp) []const u8 {
        return switch (self) {
            .copy => "Copying",
            .move => "Moving",
            .trash => "Trashing",
            .restore => "Restoring",
            .delete => "Deleting",
            .query => "Searching",
            .other => "Working on",
        };
    }

    /// The past-tense verb for a finished job of this kind.
    pub fn doneVerb(self: JobOp) []const u8 {
        return switch (self) {
            .copy => "Copied",
            .move => "Moved",
            .trash => "Trashed",
            .restore => "Restored",
            .delete => "Deleted",
            .query => "Searched",
            .other => "Finished",
        };
    }
};

test "wire verbs classify, and only copies count bytes" {
    const t = std.testing;
    try t.expectEqual(JobOp.copy, JobOp.fromWire("copy", false));
    try t.expectEqual(JobOp.move, JobOp.fromWire("cross_copy", true));
    try t.expectEqual(JobOp.copy, JobOp.fromWire("cross_copy", false));
    try t.expectEqual(JobOp.trash, JobOp.fromWire("trash", false));
    try t.expectEqual(JobOp.restore, JobOp.fromWire("trash_restore", false));
    try t.expectEqual(JobOp.delete, JobOp.fromWire("delete_tree", false));
    try t.expectEqual(JobOp.delete, JobOp.fromWire("secure_delete", false));
    try t.expectEqual(JobOp.query, JobOp.fromWire("find", false));
    try t.expectEqual(JobOp.query, JobOp.fromWire("panelize", false));
    try t.expectEqual(JobOp.other, JobOp.fromWire("perm_tree", false));
    try t.expectEqual(JobOp.other, JobOp.fromWire("archive_create", false));
    try t.expect(JobOp.copy.countsBytes() and JobOp.move.countsBytes());
    try t.expect(!JobOp.trash.countsBytes() and !JobOp.other.countsBytes());
    try t.expect(!JobOp.query.inStrip() and JobOp.trash.inStrip());
}

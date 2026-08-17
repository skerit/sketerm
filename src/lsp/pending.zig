//! Deferred `WorkspaceEdit` hunks — the queue a cross-file edit parks
//! in while its document is still loading.
//!
//! A rename touching four files must not leave three of them alone
//! because one had no tab yet (or was being reloaded from disk), and
//! `reportEditOutcome` has already told the user it applied. So the
//! hunk waits here for the bytes, and the ONLY two outcomes are
//! "applied" and "reported": an entry that is silently forgotten is a
//! lost edit plus a leak.
//!
//! GTK-free, in both test roots: the manager owns tabs and widgets,
//! this owns the bytes and the identity rule.

const std = @import("std");
const pos = @import("position.zig");

pub const Entry = struct {
    /// Tab spec (`local:/path` or `host:/path`), owned. For the report
    /// only — identity is `tab_id`.
    spec: []u8,
    /// The `TextEdit[]` re-serialized, owned: a `std.json.Value`
    /// borrows its parse arena, which dies with the response.
    edits: []u8,
    /// Captured at queue time because the connection that produced
    /// these edits may be gone by the time they apply.
    enc: pos.Encoding,
    tab_id: u64,
    /// The LOAD these edits were queued against, never a document
    /// revision: a load REPLACES the document object (revisions
    /// restart at 0) and a reload-in-place moves the revision on by
    /// design, so comparing revisions across the two either passes by
    /// accident or rejects a legitimate edit.
    load_gen: u64,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.spec);
        alloc.free(self.edits);
    }
};

pub const Queue = struct {
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.items.deinit(alloc);
    }

    pub fn clear(self: *Queue, alloc: std.mem.Allocator) void {
        for (self.items.items) |e| e.deinit(alloc);
        self.items.clearRetainingCapacity();
    }

    pub fn len(self: *const Queue) usize {
        return self.items.items.len;
    }

    /// Queue a copy of `spec` and `edits`. Order is preserved: the
    /// server's edit order for one document is its own answer.
    pub fn push(
        self: *Queue,
        alloc: std.mem.Allocator,
        spec: []const u8,
        edits: []const u8,
        enc: pos.Encoding,
        tab_id: u64,
        load_gen: u64,
    ) !void {
        const owned_spec = try alloc.dupe(u8, spec);
        errdefer alloc.free(owned_spec);
        const owned_edits = try alloc.dupe(u8, edits);
        errdefer alloc.free(owned_edits);
        try self.items.append(alloc, .{
            .spec = owned_spec,
            .edits = owned_edits,
            .enc = enc,
            .tab_id = tab_id,
            .load_gen = load_gen,
        });
    }

    pub const Taken = struct {
        /// Entries to apply, in queue order. Owned by the caller, which
        /// must `deinit` each one.
        ready: std.ArrayList(Entry) = .empty,
        /// Entries dropped because the document that arrived is not the
        /// one they were queued against.
        stale: usize = 0,
    };

    /// Remove every entry for `tab_id`, splitting them by load.
    ///
    /// The tab keeps NOTHING queued afterwards, whichever way each
    /// entry went — that is what makes "applied or reported" total.
    pub fn take(self: *Queue, alloc: std.mem.Allocator, tab_id: u64, load_gen: u64) Taken {
        var out = Taken{};
        var i: usize = 0;
        while (i < self.items.items.len) {
            const e = self.items.items[i];
            if (e.tab_id != tab_id) {
                i += 1;
                continue;
            }
            _ = self.items.orderedRemove(i);
            if (e.load_gen != load_gen) {
                e.deinit(alloc);
                out.stale += 1;
                continue;
            }
            out.ready.append(alloc, e) catch {
                e.deinit(alloc);
                out.stale += 1;
            };
        }
        return out;
    }

    /// Remove every entry for `tab_id` without applying any, returning
    /// how many were lost so the caller can say so out loud.
    pub fn drop(self: *Queue, alloc: std.mem.Allocator, tab_id: u64) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].tab_id != tab_id) {
                i += 1;
                continue;
            }
            const e = self.items.orderedRemove(i);
            e.deinit(alloc);
            n += 1;
        }
        return n;
    }
};

const testing = std.testing;

fn deinitTaken(alloc: std.mem.Allocator, taken: *Queue.Taken) void {
    for (taken.ready.items) |e| e.deinit(alloc);
    taken.ready.deinit(alloc);
}

test "lsp pending: a load delivers this tab's edits and leaves the others" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, "local:/a.zig", "[{\"a\":1}]", .utf16, 7, 3);
    try q.push(a, "local:/b.zig", "[{\"b\":2}]", .utf8, 9, 4);
    try q.push(a, "local:/a.zig", "[{\"a\":3}]", .utf16, 7, 3);

    var taken = q.take(a, 7, 3);
    defer deinitTaken(a, &taken);
    try testing.expectEqual(@as(usize, 2), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 0), taken.stale);
    try testing.expectEqualStrings("[{\"a\":1}]", taken.ready.items[0].edits);
    try testing.expectEqualStrings("[{\"a\":3}]", taken.ready.items[1].edits);
    try testing.expectEqual(pos.Encoding.utf16, taken.ready.items[0].enc);
    // The other document's hunk is untouched — it is still loading.
    try testing.expectEqual(@as(usize, 1), q.len());
}

test "lsp pending: a reload that moves the revision still delivers" {
    // The scenario this exists for: a rename lands while THIS file is
    // being reloaded because it changed on disk. The reload keeps the
    // document object and advances its revision by design, so nothing
    // about the revision may decide the outcome — only the load the
    // edits were queued against.
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, "local:/reloading.zig", "[{\"r\":1}]", .utf16, 11, 5);

    var taken = q.take(a, 11, 5);
    defer deinitTaken(a, &taken);
    try testing.expectEqual(@as(usize, 1), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 0), taken.stale);
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "lsp pending: a different load is stale, and nothing stays queued" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, "local:/a.zig", "[{\"a\":1}]", .utf16, 7, 3);

    var taken = q.take(a, 7, 4);
    defer deinitTaken(a, &taken);
    try testing.expectEqual(@as(usize, 0), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 1), taken.stale);
    // Reported, not requeued: a second load must not resurrect it.
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "lsp pending: a closing tab loses its edits countably" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, "local:/gone.zig", "[{\"g\":1}]", .utf16, 2, 1);
    try q.push(a, "local:/gone.zig", "[{\"g\":2}]", .utf16, 2, 1);
    try q.push(a, "local:/stay.zig", "[{\"s\":1}]", .utf16, 3, 1);

    try testing.expectEqual(@as(usize, 2), q.drop(a, 2));
    try testing.expectEqual(@as(usize, 1), q.len());
    try testing.expectEqual(@as(usize, 0), q.drop(a, 2));
}

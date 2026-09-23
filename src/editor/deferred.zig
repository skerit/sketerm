//! Edits waiting for a document to LOAD: the queue a cross-file change
//! parks in while one of its files is still being read.
//!
//! A rename, a code action or a project-wide replace touching four
//! files must not leave three of them alone because one had no tab yet
//! (or was being reloaded from disk), and the outcome line has already
//! told the user it applied. So the change waits here for the bytes, and
//! the ONLY two outcomes are "applied" and "reported": an entry that is
//! silently forgotten is a lost edit plus a leak.
//!
//! The payload is opaque here; `kind` names the owner that serialized it
//! and knows how to apply it. GTK-free, in both test roots.

const std = @import("std");

pub const Kind = enum {
    /// A language server's `TextEdit[]` (ui/editorlsp.zig).
    lsp_text_edits,
    /// A project-wide replace, re-planned against the loaded text
    /// (ui/editorproj.zig).
    project_replace,
};

pub const Entry = struct {
    kind: Kind,
    /// Tab spec (`local:/path` or `host:/path`), owned. For the report
    /// only — identity is `tab_id`.
    spec: []u8,
    /// What the owner of `kind` needs to apply the change, owned.
    payload: []u8,
    tab_id: u64,
    /// The LOAD this entry was queued against, never a document
    /// revision: a load REPLACES the document object (revisions restart)
    /// and a reload-in-place moves the revision on by design, so
    /// comparing revisions across the two either passes by accident or
    /// rejects a legitimate edit.
    load_gen: u64,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.spec);
        alloc.free(self.payload);
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

    /// Entries of one kind still waiting, for "N still opening" reports.
    pub fn countKind(self: *const Queue, kind: Kind) usize {
        var n: usize = 0;
        for (self.items.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }

    /// Queue copies of `spec` and `payload`. Order is preserved: the
    /// order of one document's changes is its producer's answer.
    pub fn push(
        self: *Queue,
        alloc: std.mem.Allocator,
        kind: Kind,
        spec: []const u8,
        payload: []const u8,
        tab_id: u64,
        load_gen: u64,
    ) !void {
        const owned_spec = try alloc.dupe(u8, spec);
        errdefer alloc.free(owned_spec);
        const owned_payload = try alloc.dupe(u8, payload);
        errdefer alloc.free(owned_payload);
        try self.items.append(alloc, .{
            .kind = kind,
            .spec = owned_spec,
            .payload = owned_payload,
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

        pub fn deinit(self: *Taken, alloc: std.mem.Allocator) void {
            for (self.ready.items) |e| e.deinit(alloc);
            self.ready.deinit(alloc);
        }
    };

    /// Remove every entry for `tab_id`, splitting them by load.
    ///
    /// The tab keeps NOTHING queued afterwards, whichever way each entry
    /// went — that is what makes "applied or reported" total.
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

test "deferred: a load delivers this tab's entries and leaves the others" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, .lsp_text_edits, "local:/a.zig", "[{\"a\":1}]", 7, 3);
    try q.push(a, .project_replace, "local:/b.zig", "{\"b\":2}", 9, 4);
    try q.push(a, .lsp_text_edits, "local:/a.zig", "[{\"a\":3}]", 7, 3);

    var taken = q.take(a, 7, 3);
    defer taken.deinit(a);
    try testing.expectEqual(@as(usize, 2), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 0), taken.stale);
    try testing.expectEqualStrings("[{\"a\":1}]", taken.ready.items[0].payload);
    try testing.expectEqualStrings("[{\"a\":3}]", taken.ready.items[1].payload);
    // The other document's entry is untouched — it is still loading.
    try testing.expectEqual(@as(usize, 1), q.len());
    try testing.expectEqual(@as(usize, 1), q.countKind(.project_replace));
    try testing.expectEqual(@as(usize, 0), q.countKind(.lsp_text_edits));
}

test "deferred: a reload that moves the revision still delivers" {
    // A rename lands while THIS file is being reloaded because it changed
    // on disk. The reload keeps the document object and advances its
    // revision by design, so only the load decides the outcome.
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, .lsp_text_edits, "local:/reloading.zig", "[{\"r\":1}]", 11, 5);

    var taken = q.take(a, 11, 5);
    defer taken.deinit(a);
    try testing.expectEqual(@as(usize, 1), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 0), taken.stale);
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "deferred: a different load is stale, and nothing stays queued" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, .project_replace, "local:/a.zig", "{}", 7, 3);

    var taken = q.take(a, 7, 4);
    defer taken.deinit(a);
    try testing.expectEqual(@as(usize, 0), taken.ready.items.len);
    try testing.expectEqual(@as(usize, 1), taken.stale);
    // Reported, not requeued: a second load must not resurrect it.
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "deferred: a closing tab loses its entries countably" {
    const a = testing.allocator;
    var q = Queue{};
    defer q.deinit(a);
    try q.push(a, .lsp_text_edits, "local:/gone.zig", "[{\"g\":1}]", 2, 1);
    try q.push(a, .project_replace, "local:/gone.zig", "{}", 2, 1);
    try q.push(a, .lsp_text_edits, "local:/stay.zig", "[{\"s\":1}]", 3, 1);

    try testing.expectEqual(@as(usize, 2), q.drop(a, 2));
    try testing.expectEqual(@as(usize, 1), q.len());
    try testing.expectEqual(@as(usize, 0), q.drop(a, 2));
}

//! What an external drop onto a web page carries, and what becomes of
//! it: GTK-free, so the rules are unit-tested. `dragdrop.zig` fills a
//! `Data` from the drag and plays it into the helper as `input_drag`.

const std = @import("std");
const proto = @import("../../web/protocol.zig");

/// Prefix of the stand-in path a remote entry carries while the drag
/// hovers: the page only learns a file's NAME before the drop, and the
/// real staged path replaces it when the drop fetches the file.
pub const PENDING_DIR = "/sketerm-pending-drop/";

pub const Data = struct {
    allocator: std.mem.Allocator,
    /// Paths on this host, in drag order; stand-ins for remote entries.
    files: std.ArrayList([]const u8) = .empty,
    /// Some entry lives on another host and is staged at the drop.
    remote: bool = false,
    url: ?[]const u8 = null,
    text: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Data {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Data) void {
        self.clearFiles();
        self.files.deinit(self.allocator);
        if (self.url) |u| self.allocator.free(u);
        if (self.text) |t| self.allocator.free(t);
        self.* = undefined;
    }

    pub fn clearFiles(self: *Data) void {
        for (self.files.items) |f| self.allocator.free(f);
        self.files.clearRetainingCapacity();
        self.remote = false;
    }

    /// Add one sketerm drag record: a bare absolute path is local, a
    /// `host:/path` spec is remote and stands in until the drop.
    pub fn addSpec(self: *Data, spec: []const u8) !void {
        if (spec.len == 0) return;
        if (spec[0] == '/') return self.addPath(spec);
        const colon = std.mem.indexOf(u8, spec, ":/") orelse return;
        const base = std.fs.path.basename(spec[colon + 1 ..]);
        const stand_in = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ PENDING_DIR, if (base.len == 0) "file" else base });
        errdefer self.allocator.free(stand_in);
        try self.files.append(self.allocator, stand_in);
        self.remote = true;
    }

    pub fn addPath(self: *Data, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.files.append(self.allocator, owned);
    }

    /// Keep the first link only: a page drop carries one.
    pub fn addUrl(self: *Data, url: []const u8) !void {
        if (self.url != null or url.len == 0) return;
        self.url = try self.allocator.dupe(u8, url);
    }

    pub fn setText(self: *Data, text: []const u8) !void {
        if (self.text) |t| self.allocator.free(t);
        self.text = null;
        if (text.len != 0) self.text = try self.allocator.dupe(u8, text);
    }

    pub fn empty(self: *const Data) bool {
        return self.files.items.len == 0 and self.url == null and self.text == null;
    }

    /// The `input_drag` frame for this data. Borrows from `self`.
    pub fn frame(self: *const Data, view: u32, kind: proto.DragKind, x: i32, y: i32, ops: u8, with_data: bool) proto.InputDrag {
        var f = proto.InputDrag{ .view = view, .kind = @intFromEnum(kind), .x = x, .y = y, .mods = 0, .ops = ops };
        if (!with_data) return f;
        f.flags = proto.InputDrag.FLAG_DATA;
        f.files = self.files.items;
        f.url = self.url orelse "";
        f.text = .{ .s = self.text orelse "" };
        return f;
    }
};

/// What a client opens itself when its helper cannot take the drop (no
/// "drag-drop" capability): a browser opens one dropped file or link,
/// and a text drop has always meant "go to this address".
pub const Fallback = union(enum) { none, file: []const u8, url: []const u8, address: []const u8 };

pub fn fallback(data: *const Data) Fallback {
    if (data.files.items.len != 0) return .{ .file = data.files.items[0] };
    if (data.url) |u| return .{ .url = u };
    if (data.text) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        // A multi-line text is not an address; never navigate to it.
        if (trimmed.len != 0 and std.mem.indexOfScalar(u8, trimmed, '\n') == null) return .{ .address = trimmed };
    }
    return .none;
}

test "sketerm specs: local paths pass through, remote ones stand in by name until the drop" {
    const t = std.testing;
    var d = Data.init(t.allocator);
    defer d.deinit();
    try d.addSpec("/home/u/a b.txt");
    try t.expect(!d.remote);
    try d.addSpec("rbox:/srv/report \u{e9}.pdf");
    try d.addSpec("");
    try d.addSpec("nonsense");
    try t.expect(d.remote);
    try t.expectEqual(@as(usize, 2), d.files.items.len);
    try t.expectEqualStrings("/home/u/a b.txt", d.files.items[0]);
    try t.expectEqualStrings(PENDING_DIR ++ "report \u{e9}.pdf", d.files.items[1]);
    // The real staged paths replace every entry at the drop.
    d.clearFiles();
    try t.expect(!d.remote);
    try t.expect(d.empty());
}

test "the frame carries data only when asked, borrowing the lists" {
    const t = std.testing;
    var d = Data.init(t.allocator);
    defer d.deinit();
    try d.addPath("/tmp/x");
    try d.addUrl("https://a.example/");
    try d.addUrl("https://b.example/");
    try d.setText("hello");
    const bare = d.frame(3, .over, 10, 20, proto.drag_op_copy, false);
    try t.expectEqual(@as(u8, 0), bare.flags);
    try t.expectEqual(@as(usize, 0), bare.files.len);
    const full = d.frame(3, .drop, 10, 20, proto.drag_op_copy, true);
    try t.expectEqual(proto.InputDrag.FLAG_DATA, full.flags);
    try t.expectEqualStrings("/tmp/x", full.files[0]);
    try t.expectEqualStrings("https://a.example/", full.url);
    try t.expectEqualStrings("hello", full.text.s);
}

test "without the capability: one file or link opens, a one-line text is an address, never a quoted path" {
    const t = std.testing;
    var d = Data.init(t.allocator);
    defer d.deinit();
    try t.expectEqual(Fallback.none, fallback(&d));
    try d.setText("  multi\nline  ");
    try t.expectEqual(Fallback.none, fallback(&d));
    try d.setText(" example.org \n");
    try t.expectEqualStrings("example.org", fallback(&d).address);
    try d.addUrl("https://a.example/");
    try t.expectEqualStrings("https://a.example/", fallback(&d).url);
    try d.addPath("/tmp/one.html");
    try d.addPath("/tmp/two.html");
    try t.expectEqualStrings("/tmp/one.html", fallback(&d).file);
    // A remote helper cannot open files of this host.
    d.clearFiles();
    try t.expectEqualStrings("https://a.example/", fallback(&d).url);
}

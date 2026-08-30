//! Finding an assistant's browser helper from its daemon socket: the
//! MCP instance layout (`src/ipc/webdrive.zig`, "Discoverability")
//! puts every helper socket beside the instance's `mux.sock` as
//! `web.sock` (the direct route) or `web-<slug>.sock` (a routed
//! engine), each with a `.json` presence file naming the web SESSION
//! it renders into. This is the one resolver for that layout, shared
//! by the GUI's local watch (`src/ui/webwatch.zig`) and the daemon's
//! `web_helper_connect` (the remote watch), so the two cannot drift.
//! libc only: it is compiled into `sketerm-mux`.

const std = @import("std");
const c = @import("../c.zig").c;

/// Longest path this resolver handles; a unix socket path is far
/// shorter, so a longer instance directory could never bind anyway.
pub const MAX_PATH = 512;

/// The helper socket serving `session` of the instance whose daemon
/// listens on `mux_socket`: the sibling `web*.json` presence file
/// naming that session, with `.sock` for `.json`. When no presence
/// file names the session (an empty session, or a helper still
/// starting up), the direct route's `web.sock` is the answer.
pub fn helperSocketFor(buf: []u8, mux_socket: []const u8, session: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(mux_socket) orelse return null;
    if (session.len != 0) {
        var dir_z: [MAX_PATH:0]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch return null;
        if (c.opendir(dz.ptr)) |d| {
            defer _ = c.closedir(d);
            while (c.readdir(d)) |ent| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (!std.mem.startsWith(u8, name, "web") or !std.mem.endsWith(u8, name, ".json")) continue;
                var path_z: [MAX_PATH:0]u8 = undefined;
                const pz = std.fmt.bufPrintZ(&path_z, "{s}/{s}", .{ dir, name }) catch continue;
                if (!presenceNamesSession(pz, session)) continue;
                return std.fmt.bufPrint(buf, "{s}/{s}.sock", .{ dir, name[0 .. name.len - ".json".len] }) catch null;
            }
        }
    }
    return std.fmt.bufPrint(buf, "{s}/web.sock", .{dir}) catch null;
}

/// Whether the presence file at `path` carries `"session":"<session>"`.
fn presenceNamesSession(path: [:0]const u8, session: []const u8) bool {
    const f = c.fopen(path.ptr, "r") orelse return false;
    defer _ = c.fclose(f);
    var line: [8704]u8 = undefined;
    const n = c.fread(&line, 1, line.len, f);
    if (n == 0) return false;
    var needle_buf: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"session\":\"{s}\"", .{session}) catch return false;
    return std.mem.indexOf(u8, line[0..n], needle) != null;
}

test "helperSocketFor falls back to the direct route's web.sock beside the mux socket" {
    var buf: [MAX_PATH]u8 = undefined;
    const got = helperSocketFor(&buf, "/tmp/sk-none-such-dir/mux.sock", "web-1-abc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/sk-none-such-dir/web.sock", got);
    const bare = helperSocketFor(&buf, "/tmp/sk-none-such-dir/mux.sock", "") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/sk-none-such-dir/web.sock", bare);
}

test "helperSocketFor picks the routed helper whose presence file names the session" {
    var dir_buf: [MAX_PATH:0]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sk-webpresence-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    var json_buf: [MAX_PATH:0]u8 = undefined;
    const json = try std.fmt.bufPrintZ(&json_buf, "{s}/web-tor.json", .{dir});
    defer _ = c.unlink(json.ptr);
    {
        const f = c.fopen(json.ptr, "w") orelse return error.TestUnexpectedResult;
        defer _ = c.fclose(f);
        const body = "{\"mcp_pid\":1,\"helper_pid\":2,\"client\":\"x\",\"started_at_ms\":3,\"session\":\"web-9-cafe\",\"mux_socket\":\"/x/mux.sock\"}\n";
        _ = c.fwrite(body.ptr, 1, body.len, f);
    }
    var mux_buf: [MAX_PATH]u8 = undefined;
    const mux = try std.fmt.bufPrint(&mux_buf, "{s}/mux.sock", .{dir});
    var want_buf: [MAX_PATH]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s}/web-tor.sock", .{dir});
    var buf: [MAX_PATH]u8 = undefined;
    const got = helperSocketFor(&buf, mux, "web-9-cafe") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(want, got);
    // Another session is not that helper's.
    var other_buf: [MAX_PATH]u8 = undefined;
    const other = try std.fmt.bufPrint(&other_buf, "{s}/web.sock", .{dir});
    const miss = helperSocketFor(&buf, mux, "web-9-dead") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(other, miss);
}

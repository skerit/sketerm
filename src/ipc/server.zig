//! Remote-control server: GSocketService listening on a Unix socket
//! at $XDG_RUNTIME_DIR/sketerm/<pid>.sock, JSON-lines protocol.
//!
//! Transport only — command execution is delegated to the dispatch
//! callback (Window.ipcDispatch). Accepts and reads land on the GLib
//! main loop via read_line_async, so dispatch always runs on the
//! main thread where Screen/GTK state lives; no new threads.

const std = @import("std");
const c = @import("../c.zig").c;
const protocol = @import("protocol.zig");

pub const DispatchFn = *const fn (ctx: *anyopaque, req: protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) void;

pub const Server = struct {
    allocator: std.mem.Allocator,
    service: *c.GSocketService,
    /// NUL-terminated socket path, owned.
    path: [:0]u8,
    dispatch_ctx: *anyopaque,
    dispatch: DispatchFn,

    pub fn deinit(self: *Server) void {
        c.g_socket_service_stop(self.service);
        c.g_socket_listener_close(@ptrCast(self.service));
        c.g_object_unref(self.service);
        _ = c.g_unlink(self.path.ptr);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

/// Compute the per-process socket path. Caller frees.
pub fn defaultSocketPath(allocator: std.mem.Allocator) ![:0]u8 {
    const rt = @import("../util/platform.zig").runtimeDir();
    return std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, c.getpid() }, 0);
}

/// Create the socket dir (0700), bind, and start listening. The
/// returned Server owns `path`.
pub fn start(
    allocator: std.mem.Allocator,
    path: [:0]u8,
    dispatch_ctx: *anyopaque,
    dispatch: DispatchFn,
) !*Server {
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadPath;
    const dir_z = try allocator.dupeZ(u8, path[0..dir_end]);
    defer allocator.free(dir_z);
    if (c.g_mkdir_with_parents(dir_z.ptr, 0o700) != 0) return error.MkdirFailed;
    // Stale socket from a crashed previous run with the same pid.
    _ = c.g_unlink(path.ptr);

    const service = c.g_socket_service_new() orelse return error.ServiceFailed;
    errdefer c.g_object_unref(service);

    const addr = c.g_unix_socket_address_new(path.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    if (c.g_socket_listener_add_address(
        @ptrCast(service),
        addr,
        c.G_SOCKET_TYPE_STREAM,
        c.G_SOCKET_PROTOCOL_DEFAULT,
        null,
        null,
        &gerr,
    ) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        return error.BindFailed;
    }

    const self = try allocator.create(Server);
    self.* = .{
        .allocator = allocator,
        .service = service,
        .path = path,
        .dispatch_ctx = dispatch_ctx,
        .dispatch = dispatch,
    };
    _ = c.g_signal_connect_data(service, "incoming", @ptrCast(&onIncoming), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    return self;
}

/// Per-connection state. Freed when read_line returns null (EOF) or
/// errors. The connection ref keeps the streams alive between async
/// reads.
const Conn = struct {
    server: *Server,
    connection: *c.GSocketConnection,
    din: *c.GDataInputStream,
    pending_out: ?[]u8 = null,
};

fn onIncoming(
    _: *c.GSocketService,
    connection: *c.GSocketConnection,
    _: ?*c.GObject,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const server: *Server = @ptrCast(@alignCast(user.?));
    const conn = server.allocator.create(Conn) catch return 0;
    _ = c.g_object_ref(connection);
    const in_stream = c.g_io_stream_get_input_stream(@ptrCast(connection));
    const din = c.g_data_input_stream_new(in_stream);
    // Bound the read buffer so a client streaming a newline-less line
    // can't make GLib buffer unbounded memory before handleLine's
    // MAX_LINE check runs. GDataInputStream is a GBufferedInputStream;
    // read_line stops filling once the buffer is full, so an oversize
    // line is rejected at the transport. Small slack over MAX_LINE.
    c.g_buffered_input_stream_set_buffer_size(@ptrCast(din), protocol.MAX_LINE + 64);
    conn.* = .{ .server = server, .connection = connection, .din = din };
    readNextLine(conn);
    return 1; // handled
}

fn readNextLine(conn: *Conn) void {
    c.g_data_input_stream_read_line_async(
        conn.din,
        c.G_PRIORITY_DEFAULT,
        null,
        @ptrCast(&onLine),
        @ptrCast(conn),
    );
}

fn closeConn(conn: *Conn) void {
    var gerr: [*c]c.GError = null;
    _ = c.g_io_stream_close(@ptrCast(conn.connection), null, &gerr);
    if (gerr != null) c.g_error_free(gerr);
    c.g_object_unref(conn.din);
    c.g_object_unref(conn.connection);
    if (conn.pending_out) |out| conn.server.allocator.free(out);
    conn.server.allocator.destroy(conn);
}

fn onWrite(_: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const conn: *Conn = @ptrCast(@alignCast(user.?));
    var written: c.gsize = 0;
    var gerr: [*c]c.GError = null;
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn.connection));
    const ok = c.g_output_stream_write_all_finish(out_stream, res, &written, &gerr);
    if (gerr != null) c.g_error_free(gerr);
    if (conn.pending_out) |out| conn.server.allocator.free(out);
    conn.pending_out = null;
    if (ok == 0) {
        closeConn(conn);
        return;
    }
    readNextLine(conn);
}

fn onLine(source: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    _ = source;
    const conn: *Conn = @ptrCast(@alignCast(user.?));
    const server = conn.server;
    var len: c.gsize = 0;
    var gerr: [*c]c.GError = null;
    const line_raw = c.g_data_input_stream_read_line_finish(conn.din, res, &len, &gerr);
    if (gerr != null) c.g_error_free(gerr);
    if (line_raw == null) {
        closeConn(conn);
        return;
    }
    defer c.g_free(line_raw);
    const line = line_raw[0..len];

    var out: std.ArrayList(u8) = .empty;
    handleLine(server, line, &out);
    const owned = out.toOwnedSlice(server.allocator) catch {
        out.deinit(server.allocator);
        closeConn(conn);
        return;
    };
    conn.pending_out = owned;
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn.connection));
    c.g_output_stream_write_all_async(out_stream, owned.ptr, owned.len, c.G_PRIORITY_DEFAULT, null, @ptrCast(&onWrite), @ptrCast(conn));
}

fn handleLine(server: *Server, line: []const u8, out: *std.ArrayList(u8)) void {
    if (line.len == 0 or line.len > protocol.MAX_LINE) {
        protocol.writeErr(out, server.allocator, "bad request") catch {};
        return;
    }
    var parsed = protocol.parseRequest(server.allocator, line) catch {
        protocol.writeErr(out, server.allocator, "invalid JSON request") catch {};
        return;
    };
    defer parsed.deinit();
    server.dispatch(server.dispatch_ctx, parsed.value, out, server.allocator);
    // Dispatch must always answer; guard against a silent fallthrough.
    if (out.items.len == 0) {
        protocol.writeErr(out, server.allocator, "internal: no response") catch {};
    }
}

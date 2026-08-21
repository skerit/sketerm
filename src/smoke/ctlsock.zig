//! One request line / one response line on a GUI's remote-control
//! socket, for the rigs that also own the compositor.
//!
//! Shared by smoke-e2e and smoke-atspi, which had identical copies. The
//! `drive` argument is not optional decoration: the rig process IS the
//! compositor brain for the GUI's toplevel, so a stage that talks IPC
//! without pumping the viewer starves configure/frame handling for its
//! whole duration.

const std = @import("std");
const c = @import("../c.zig").c;
const appdrive = @import("../ipc/appdrive.zig");

/// Connect, write `line`, read one line back. Caller frees. Null on any
/// failure, which every caller treats as "the GUI did not answer".
pub fn roundtrip(
    allocator: std.mem.Allocator,
    drive: ?*appdrive.App,
    sock_path: [:0]const u8,
    line: []const u8,
) ?[]u8 {
    if (drive) |app| app.drain();
    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_object_unref(conn);
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    var written: c.gsize = 0;
    if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);
    var rlen: c.gsize = 0;
    const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
    if (resp == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_free(resp);
    return allocator.dupe(u8, resp[0..rlen]) catch null;
}

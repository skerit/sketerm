//! A one-page PDF (a filled blue rectangle, no fonts) for the smoke rigs'
//! poster stages, written with a correct xref so no reader has to repair it.

const std = @import("std");

/// Page size in PDF points; pdftoppm renders 1 pt = 1 px at 72 dpi.
pub const WIDTH_PT = 200;
pub const HEIGHT_PT = 140;

/// @return the PDF bytes inside `buf`.
pub fn build(buf: *[2048]u8) []const u8 {
    const content = "0 0 1 rg 20 20 160 100 re f";
    var w: std.Io.Writer = .fixed(buf);
    var offsets: [4]usize = undefined;
    w.writeAll("%PDF-1.4\n") catch unreachable;
    offsets[0] = w.end;
    w.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n") catch unreachable;
    offsets[1] = w.end;
    w.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n") catch unreachable;
    offsets[2] = w.end;
    w.print("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d} {d}] /Contents 4 0 R >>\nendobj\n", .{ WIDTH_PT, HEIGHT_PT }) catch unreachable;
    offsets[3] = w.end;
    w.print("4 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content }) catch unreachable;
    const xref = w.end;
    w.writeAll("xref\n0 5\n0000000000 65535 f \n") catch unreachable;
    for (offsets) |off| w.print("{d:0>10} 00000 n \n", .{off}) catch unreachable;
    w.print("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref}) catch unreachable;
    return buf[0..w.end];
}

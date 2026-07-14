//! WAV capture of a Pulse stream's PCM — the headless-verification
//! target for sketerm's audio sink (`launch_app audio_path`). Plain
//! libc file IO, musl-clean, no allocator: the daemon feeds it the
//! same PCM unit payloads it ships to viewers, and the RIFF sizes
//! are patched on close. WAV (not mp3/ogg) because the daemon links
//! libc only — no encoder libraries in its graph.

const std = @import("std");
const c = @import("../c.zig").c;

/// PA sample-format code → WAV encoding. Null = format we don't map
/// (big-endian / law codecs); the caller logs and skips capture.
fn wavSpec(pa_format: u8) ?struct { bits: u16, tag: u16 } {
    return switch (pa_format) {
        0 => .{ .bits = 8, .tag = 1 }, // u8 PCM
        3 => .{ .bits = 16, .tag = 1 }, // s16le
        5 => .{ .bits = 32, .tag = 3 }, // f32le (IEEE float)
        7 => .{ .bits = 32, .tag = 1 }, // s32le
        9 => .{ .bits = 24, .tag = 1 }, // s24le packed
        else => null,
    };
}

pub const Writer = struct {
    f: *c.FILE,
    data_bytes: u64 = 0,

    /// @return null when the path can't be opened or the PA format
    /// has no little-endian WAV mapping.
    pub fn open(path: [*:0]const u8, pa_format: u8, channels: u8, rate: u32) ?Writer {
        const spec = wavSpec(pa_format) orelse return null;
        const f = c.fopen(path, "wb") orelse return null;
        var hdr: [44]u8 = undefined;
        @memcpy(hdr[0..4], "RIFF");
        std.mem.writeInt(u32, hdr[4..8], 0, .little); // patched on close
        @memcpy(hdr[8..16], "WAVEfmt ");
        std.mem.writeInt(u32, hdr[16..20], 16, .little); // fmt chunk size
        std.mem.writeInt(u16, hdr[20..22], spec.tag, .little);
        std.mem.writeInt(u16, hdr[22..24], channels, .little);
        std.mem.writeInt(u32, hdr[24..28], rate, .little);
        const block_align: u16 = @as(u16, channels) * (spec.bits / 8);
        std.mem.writeInt(u32, hdr[28..32], rate * block_align, .little); // byte rate
        std.mem.writeInt(u16, hdr[32..34], block_align, .little);
        std.mem.writeInt(u16, hdr[34..36], spec.bits, .little);
        @memcpy(hdr[36..40], "data");
        std.mem.writeInt(u32, hdr[40..44], 0, .little); // patched on close
        if (c.fwrite(&hdr, 1, hdr.len, f) != hdr.len) {
            _ = c.fclose(f);
            return null;
        }
        return .{ .f = f };
    }

    pub fn write(self: *Writer, pcm: []const u8) void {
        if (pcm.len == 0) return;
        self.data_bytes += c.fwrite(pcm.ptr, 1, pcm.len, self.f);
    }

    /// Patches the RIFF/data sizes and closes. A SIGKILLed daemon
    /// leaves them zero; `ffmpeg`/`sox` still read such files.
    pub fn close(self: *Writer) void {
        const data: u32 = @intCast(@min(self.data_bytes, 0xffff_ffff - 36));
        _ = c.fflush(self.f);
        var b: [4]u8 = undefined;
        if (c.fseek(self.f, 4, c.SEEK_SET) == 0) {
            std.mem.writeInt(u32, &b, 36 + data, .little);
            _ = c.fwrite(&b, 1, 4, self.f);
        }
        if (c.fseek(self.f, 40, c.SEEK_SET) == 0) {
            std.mem.writeInt(u32, &b, data, .little);
            _ = c.fwrite(&b, 1, 4, self.f);
        }
        _ = c.fclose(self.f);
    }
};

// ─── tests ──────────────────────────────────────────────────────

test "wav writer round-trips header and data sizes" {
    const t_ = std.testing;
    var path_buf: [256]u8 = undefined;
    const dir = if (std.c.getenv("TMPDIR")) |d| std.mem.span(d) else "/tmp";
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/sketerm-wavcap-test-{d}.wav", .{ dir, c.getpid() });

    var w = Writer.open(path.ptr, 3, 2, 44100) orelse return error.OpenFailed;
    const pcm = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    w.write(&pcm);
    w.close();

    const f = c.fopen(path.ptr, "rb") orelse return error.OpenFailed;
    defer {
        _ = c.fclose(f);
        _ = c.remove(path.ptr);
    }
    var buf: [52]u8 = undefined;
    try t_.expectEqual(buf.len, c.fread(&buf, 1, buf.len, f));
    try t_.expectEqualStrings("RIFF", buf[0..4]);
    try t_.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, buf[4..8], .little));
    try t_.expectEqualStrings("WAVE", buf[8..12]);
    try t_.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[20..22], .little)); // PCM
    try t_.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[22..24], .little)); // stereo
    try t_.expectEqual(@as(u32, 44100), std.mem.readInt(u32, buf[24..28], .little));
    try t_.expectEqual(@as(u16, 16), std.mem.readInt(u16, buf[34..36], .little)); // bits
    try t_.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[40..44], .little)); // data size
    try t_.expectEqualSlices(u8, &pcm, buf[44..52]);
}

test "unsupported PA format refuses to open" {
    const t_ = std.testing;
    try t_.expectEqual(@as(?Writer, null), Writer.open("/nonexistent-dir/x.wav", 3, 2, 44100));
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-wavcap-badfmt-{d}.wav", .{c.getpid()});
    try t_.expectEqual(@as(?Writer, null), Writer.open(path.ptr, 4, 2, 44100)); // s16be
}

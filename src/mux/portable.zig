//! The deployable portable daemon targets: the one declaring home for the set.
//!
//! Imported by build.zig (artifact naming) and by `deploy.zig` (header
//! recognition, remote platform match). std-only on purpose: build.zig
//! compiles it. `dist/stage.sh` cannot import Zig, so `dist/test-install.sh`
//! drift-tests its target list and naming rule against this table.

const std = @import("std");

pub const BASE_NAME = "sketerm-mux-portable";

/// One deployable target; `uname` is the remote `uname -s:uname -m` case pattern.
pub const Target = struct {
    triple: []const u8,
    os: Os,
    /// ELF `e_machine` or Mach-O `cputype`, per `os`.
    machine: u32,
    uname: []const u8,
    /// Linux keeps the historical unsuffixed name (installed packages and
    /// `$SKETERM_MUX_PORTABLE` users rely on it; a package ships one Linux
    /// arch); every other OS appends its triple.
    artifact: []const u8,

    pub const Os = enum { linux, macos };
};

fn row(comptime triple: []const u8, comptime os: Target.Os, machine: u32, uname: []const u8) Target {
    return .{
        .triple = triple,
        .os = os,
        .machine = machine,
        .uname = uname,
        .artifact = switch (os) {
            .linux => BASE_NAME,
            else => BASE_NAME ++ "-" ++ triple,
        },
    };
}

const MACHO_MAGIC_64: u32 = 0xfeedfacf;
const MACHO_CPU_ARM64: u32 = 0x0100000c;

// One `row(` per line, triple first: dist/test-install.sh greps these.
pub const targets = [_]Target{
    row("x86_64-linux-musl", .linux, 62, "Linux:x86_64|Linux:amd64"),
    row("aarch64-linux-musl", .linux, 183, "Linux:aarch64|Linux:arm64"),
    row("aarch64-macos", .macos, MACHO_CPU_ARM64, "Darwin:arm64"),
};

/// How many header bytes `ofHeader` needs.
pub const HEADER_LEN = 20;

/// The artifact file name `zig build mux-portable -Dportable-target=<triple>` installs.
///
/// A triple outside the table keeps the unsuffixed name: it is a developer
/// build that deployment does not recognize anyway.
pub fn artifactNameForTriple(triple: []const u8) []const u8 {
    for (targets) |t| if (std.mem.eql(u8, t.triple, triple)) return t.artifact;
    return BASE_NAME;
}

/// The distinct artifact file names across the table, in table order.
pub const artifact_names = blk: {
    var names: []const []const u8 = &.{};
    for (targets) |t| {
        for (names) |seen| {
            if (std.mem.eql(u8, seen, t.artifact)) break;
        } else names = names ++ .{t.artifact};
    }
    const out = names[0..names.len].*;
    break :blk out;
};

/// The table row whose executable format and machine this header carries.
pub fn ofHeader(header: []const u8) ?*const Target {
    if (header.len < HEADER_LEN) return null;
    const os: Target.Os, const machine: u32 = if (std.mem.eql(u8, header[0..4], "\x7fELF")) blk: {
        if (header[4] != 2 or header[5] != 1) return null; // ELF64, little-endian
        break :blk .{ .linux, std.mem.readInt(u16, header[18..20], .little) };
    } else if (std.mem.readInt(u32, header[0..4], .little) == MACHO_MAGIC_64)
        .{ .macos, std.mem.readInt(u32, header[4..8], .little) }
    else
        return null;
    for (&targets) |*t| if (t.os == os and t.machine == machine) return t;
    return null;
}

test "every portable target has a distinct header identity and triple" {
    for (targets, 0..) |a, i| for (targets[i + 1 ..]) |b| {
        try std.testing.expect(!(a.os == b.os and a.machine == b.machine));
        try std.testing.expect(!std.mem.eql(u8, a.triple, b.triple));
    };
}

test "portable headers resolve to their table rows" {
    var elf = [_]u8{0} ** HEADER_LEN;
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2;
    elf[5] = 1;
    std.mem.writeInt(u16, elf[18..20], 62, .little);
    try std.testing.expectEqualStrings("x86_64-linux-musl", ofHeader(&elf).?.triple);
    std.mem.writeInt(u16, elf[18..20], 183, .little);
    try std.testing.expectEqualStrings("aarch64-linux-musl", ofHeader(&elf).?.triple);
    std.mem.writeInt(u16, elf[18..20], 3, .little);
    try std.testing.expect(ofHeader(&elf) == null);
    elf[4] = 1; // ELF32
    std.mem.writeInt(u16, elf[18..20], 62, .little);
    try std.testing.expect(ofHeader(&elf) == null);

    var macho = [_]u8{0} ** HEADER_LEN;
    std.mem.writeInt(u32, macho[0..4], MACHO_MAGIC_64, .little);
    std.mem.writeInt(u32, macho[4..8], MACHO_CPU_ARM64, .little);
    const mac = ofHeader(&macho).?;
    try std.testing.expectEqualStrings("aarch64-macos", mac.triple);
    try std.testing.expectEqualStrings("Darwin:arm64", mac.uname);
    // x86_64 Mach-O (CPU_TYPE_X86_64) is not a portable target.
    std.mem.writeInt(u32, macho[4..8], 0x01000007, .little);
    try std.testing.expect(ofHeader(&macho) == null);
    try std.testing.expect(ofHeader(macho[0..8]) == null);
}

test "artifact names keep Linux unsuffixed and are distinct per OS" {
    try std.testing.expectEqualStrings(BASE_NAME, artifactNameForTriple("x86_64-linux-musl"));
    try std.testing.expectEqualStrings(BASE_NAME, artifactNameForTriple("aarch64-linux-musl"));
    try std.testing.expectEqualStrings(BASE_NAME ++ "-aarch64-macos", artifactNameForTriple("aarch64-macos"));
    try std.testing.expectEqualStrings(BASE_NAME, artifactNameForTriple("riscv64-linux-musl"));
    const names = artifact_names;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings(BASE_NAME, names[0]);
}

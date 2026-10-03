//! A host's available memory and load average, read by one POSIX sh script
//! that runs the same on Linux (`/proc`) and macOS (`sysctl`, `vm_stat`),
//! locally or over ssh, and prints one marker line `parse` reads. A number
//! the host cannot give is `?`, which reads as unknown, never an error.

const std = @import("std");

/// The one script: `SKHOST <load1> <load5> <load15> <avail_kb> <total_kb>`.
pub const SCRIPT =
    \\l1=? l5=? l15=? avail=? total=?
    \\if [ -r /proc/loadavg ]; then read l1 l5 l15 rest < /proc/loadavg; fi
    \\if [ -r /proc/meminfo ]; then
    \\  avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    \\  total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    \\elif command -v sysctl >/dev/null 2>&1; then
    \\  set -- $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
    \\  [ $# -ge 3 ] && l1=$1 l5=$2 l15=$3
    \\  ps=$(sysctl -n hw.pagesize 2>/dev/null) mem=$(sysctl -n hw.memsize 2>/dev/null)
    \\  [ -n "$mem" ] && total=$((mem / 1024))
    \\  pages=$(vm_stat 2>/dev/null | awk '/^Pages (free|inactive|speculative):/{gsub(/\./,"",$NF); n+=$NF} END{print n+0}')
    \\  [ -n "$ps" ] && [ -n "$pages" ] && avail=$((pages * ps / 1024))
    \\fi
    \\echo "SKHOST ${l1:-?} ${l5:-?} ${l15:-?} ${avail:-?} ${total:-?}"
;

/// What the marker line says; null fields are unknown.
pub const Stats = struct {
    load1: ?f64 = null,
    load5: ?f64 = null,
    load15: ?f64 = null,
    avail_kb: ?u64 = null,
    total_kb: ?u64 = null,

    pub fn availMb(self: Stats) ?u64 {
        return if (self.avail_kb) |k| k / 1024 else null;
    }

    pub fn totalMb(self: Stats) ?u64 {
        return if (self.total_kb) |k| k / 1024 else null;
    }

    /// Nothing at all was readable.
    pub fn empty(self: Stats) bool {
        return self.load1 == null and self.avail_kb == null;
    }
};

/// The stats on the marker line of `output` (other lines, a login shell's
/// noise included, are ignored); null without one.
pub fn parse(output: []const u8) ?Stats {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "SKHOST ")) continue;
        var f = std.mem.tokenizeScalar(u8, line["SKHOST ".len..], ' ');
        var s: Stats = .{};
        s.load1 = float(f.next());
        s.load5 = float(f.next());
        s.load15 = float(f.next());
        s.avail_kb = int(f.next());
        s.total_kb = int(f.next());
        return s;
    }
    return null;
}

fn float(tok: ?[]const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, tok orelse return null) catch return null;
    return if (std.math.isFinite(v) and v >= 0) v else null;
}

fn int(tok: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, tok orelse return null, 10) catch null;
}

const t = std.testing;

test "the marker line reads on Linux and macOS, unknowns stay unknown" {
    const linux = parse("motd noise\nSKHOST 0.52 0.48 0.40 12582912 65536000\n").?;
    try t.expectEqual(@as(f64, 0.52), linux.load1.?);
    try t.expectEqual(@as(f64, 0.40), linux.load15.?);
    try t.expectEqual(@as(u64, 12288), linux.availMb().?);
    try t.expectEqual(@as(u64, 64000), linux.totalMb().?);
    // macOS prints its load with a comma in some locales; the script's
    // numbers come from sysctl, so a value that does not parse is unknown.
    const mac = parse("SKHOST 1,20 1.10 1.00 ? 16777216\r\n").?;
    try t.expect(mac.load1 == null);
    try t.expectEqual(@as(f64, 1.10), mac.load5.?);
    try t.expect(mac.avail_kb == null);
    try t.expectEqual(@as(u64, 16384), mac.totalMb().?);
    const none = parse("SKHOST ? ? ? ? ?").?;
    try t.expect(none.empty());
    try t.expect(parse("no marker here") == null);
    try t.expect(parse("") == null);
}

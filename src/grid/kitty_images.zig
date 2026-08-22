//! Kitty graphics protocol receive-side accumulator.
//!
//! Handles:
//! - Multi-chunk transmissions (`m=1` until `m=0`)
//! - Format 24 (RGB), 32 (RGBA), 100 (PNG via stb_image)
//! - Action `a=t` (transmit only, store keyed by image_id)
//! - Action `a=T` (transmit + place at cursor)
//! - Action `a=p` (place by image_id)
//! - Transmission medium `t=d` (direct base64) and `t=t`/`t=f` (file path)
//! - `o=z` zlib decompression (in `finalize`)
//! - Animation frames (`a=f`, `a=a`) — see `appendFrame` /
//!   `advanceAnimations` / `applyAnimateControl`
//!
//! Unicode placeholders (`U=1` + U+10EEEE cells) are handled in
//! `screen.zig` (`virtual_placements` + `flushPlaceholder`), which
//! tiles stored images from this manager.

const std = @import("std");
const c = @import("../c.zig").c;
const kitty = @import("../parser/kitty_image.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const image_size = @import("image_size.zig");

pub const Frame = struct {
    rgba: []u8,
    /// Delay before showing this frame, milliseconds. Default 100ms.
    delay_ms: u32 = 100,
};

pub const StoredImage = struct {
    /// Current frame's pixels. Owned by `frames[current_frame]` for
    /// animated images, or a standalone allocation when `frames` is
    /// empty (static, single-frame).
    rgba: []u8,
    width: u32,
    height: u32,
    /// Animation frames. Empty for static images. When non-empty,
    /// `rgba` aliases `frames[current_frame].rgba` and is NOT owned
    /// separately.
    frames: std.ArrayList(Frame) = .empty,
    current_frame: u32 = 0,
    /// Microsecond timestamp of the last frame advance. -1 = not yet
    /// seen by `advanceAnimations`; first call seeds the time.
    last_advance_us: i64 = -1,
    playing: bool = true,
    /// Bumps every time `current_frame` changes. Placements compare
    /// against their snapshot to detect frame transitions.
    generation: u32 = 0,
    /// Remaining loop count: -1 = infinite, 0 = stopped, N>0 = play
    /// for N more loops.
    loops_remaining: i32 = -1,
    /// Insertion order, for FIFO eviction under the memory budget.
    seq: u64 = 0,
    /// The client's own image NUMBER (`I=`), if it sent one. Zero
    /// otherwise. `d=n/N` deletes by this rather than by id.
    number: u32 = 0,

    /// Total decoded bytes retained by this image (all frames, or the
    /// standalone buffer for a static image).
    fn storedBytes(self: *const StoredImage) usize {
        if (self.frames.items.len == 0) return self.rgba.len;
        var t: usize = 0;
        for (self.frames.items) |f| t += f.rgba.len;
        return t;
    }
};

/// Hard cap on frames retained for a single animated image, so one runaway
/// `a=f` loop on a fixed id can't grow without bound (the per-image case the
/// store-byte budget alone won't catch). Oldest frames are dropped past this.
const MAX_FRAMES: usize = 1024;
/// Cap on concurrent in-flight chunked transmissions. A stream that opens
/// transmissions with distinct ids and never finalizes them would otherwise
/// grow the accum table without bound.
const MAX_ACCUMS: usize = 32;
/// Minimum allowance for zlib framing above decoded bytes.
const MIN_TRANSFER_OVERHEAD: usize = 64;

/// In-progress chunked transfer. Cleared on m=0 or first non-chunked.
pub const Accum = struct {
    /// Format and metadata captured from the FIRST chunk. Kitty
    /// allows subsequent chunks to omit metadata.
    format: u32,
    width: u32,
    height: u32,
    medium: u8,
    /// Compression flag from the first chunk (`o=z` → 1).
    compression: u32,
    /// Declared data size (`S=`), required for compressed PNG input.
    data_size: u32,
    /// Original action from the first chunk — drives whether
    /// finalize triggers a place.
    action: kitty.Action,
    /// Frame metadata captured from the first chunk (only used when
    /// `action == .transmit_frame`).
    frame_delay_ms: u32 = 100,
    frame_target: u32 = 0, // 0 = append at end
    frame_compose_from: u32 = 0,
    frame_compose_mode: u8 = 0,
    /// The client's image NUMBER (`I=`) from the first chunk, carried
    /// to the stored image so `d=n/N` can find it.
    number: u32 = 0,
    /// Concatenated base64 payload, awaiting final decode.
    payload: std.ArrayList(u8) = .empty,
    /// Set when an appendSlice into `payload` failed mid-stream. A
    /// truncated payload would decode as a corrupt image, so finalize
    /// bails out instead of feeding garbage to the decoders.
    poisoned: bool = false,

    pub fn deinit(self: *Accum, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

const RawLayout = struct {
    pixels: usize,
    input_bytes: usize,
    rgba_bytes: usize,
};

fn rawLayout(format: u32, width: u32, height: u32) ?RawLayout {
    const channels: usize = switch (format) {
        24 => 3,
        32 => 4,
        else => return null,
    };
    const input_bytes = image_size.byteLen(width, height, channels) catch return null;
    const rgba_bytes = image_size.byteLen(width, height, 4) catch return null;
    return .{
        .pixels = rgba_bytes / 4,
        .input_bytes = input_bytes,
        .rgba_bytes = rgba_bytes,
    };
}

fn inflateExact(src: []const u8, dst: []u8) bool {
    var src_reader: std.Io.Reader = .fixed(src);
    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&src_reader, .zlib, &window);
    const n = dec.reader.readSliceShort(dst) catch return false;
    if (n != dst.len) return false;
    var probe: [1]u8 = undefined;
    const extra = dec.reader.readSliceShort(&probe) catch return false;
    return extra == 0;
}

pub const Manager = struct {
    allocator: std.mem.Allocator,
    /// Image store keyed by image_id (a=t / a=p).
    store: std.AutoHashMap(u32, StoredImage),
    /// Pending chunked transfers keyed by image_id.
    accums: std.AutoHashMap(u32, Accum),
    /// image_id of the most recently-started chunked transmit. Kitty
    /// continuation chunks may omit `i=`, so we route their payload to
    /// this id. Cleared when the active transmit finalizes.
    active_transmit_id: u32 = 0,
    /// When true, finalize errors print to stderr (PNG decode fail,
    /// bad base64, RGB undersize, etc.). Wired by `--debug-images`.
    debug: bool = false,
    /// Cap on retained decoded-source bytes (0 = unlimited). Set from
    /// `config.image_memory_mb`. Past it, the OLDEST stored images are
    /// evicted FIFO — it is a retention target, never a per-image size
    /// limit. The hard per-image limit is `image_size.max_decoded_bytes`
    /// and does not move with the config.
    budget_bytes: usize = 0,
    /// Live decoded-source bytes across `store` (kept in sync by
    /// `freeStoredImage` / the insert path).
    store_bytes: usize = 0,
    /// Monotonic insertion counter feeding `StoredImage.seq`.
    seq_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .store = std.AutoHashMap(u32, StoredImage).init(allocator),
            .accums = std.AutoHashMap(u32, Accum).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        var it = self.store.iterator();
        while (it.next()) |e| self.freeStoredImage(e.value_ptr);
        self.store.deinit();
        var ait = self.accums.iterator();
        while (ait.next()) |e| e.value_ptr.deinit(self.allocator);
        self.accums.deinit();
    }

    fn freeStoredImage(self: *Manager, img: *StoredImage) void {
        // All removal paths funnel here, so the budget accounting lives here.
        const b = img.storedBytes();
        self.store_bytes -= @min(self.store_bytes, b);
        if (img.frames.items.len == 0) {
            // Static: rgba is the standalone allocation.
            self.allocator.free(img.rgba);
        } else {
            // Animated: rgba aliases frames[].rgba — free each frame.
            for (img.frames.items) |f| self.allocator.free(f.rgba);
        }
        img.frames.deinit(self.allocator);
    }

    /// Insert a freshly-decoded static image, accounting its bytes and
    /// stamping its insertion order, then evict oldest entries if the
    /// store is over budget.
    fn insertStored(self: *Manager, image_id: u32, img: StoredImage) !void {
        var v = img;
        v.seq = self.seq_counter;
        self.seq_counter += 1;
        try self.store.put(image_id, v);
        self.store_bytes += v.storedBytes();
        self.evictStoreForBudget(image_id);
    }

    /// Max encoded bytes a transmission may accumulate for the hard
    /// decoded ceiling, including bounded zlib framing overhead. Derived
    /// from `max_decoded_bytes`, not from the configured budget: lowering
    /// `image_memory_mb` must not make a legitimate image untransmittable.
    fn accumCap(self: *const Manager) usize {
        _ = self;
        const decoded = image_size.max_decoded_bytes;
        const overhead = decoded / 100 + MIN_TRANSFER_OVERHEAD;
        const transfer = std.math.add(usize, decoded, overhead) catch decoded;
        return std.base64.standard.Encoder.calcSize(transfer);
    }

    /// A frame may only extend an image that exists and has the same
    /// dimensions. Deliberately says nothing about the byte budget: a
    /// frame that does not fit evicts OTHER images (`evictStoreForBudget`
    /// after the append), it is never refused — refusing produced an
    /// animation stuck at zero frames on a low `image_memory_mb`.
    fn frameTargetValid(
        self: *const Manager,
        image_id: u32,
        acc: *const Accum,
        width: u32,
        height: u32,
    ) bool {
        if (acc.action != .transmit_frame) return true;
        const existing = self.store.get(image_id) orelse return false;
        return existing.width == width and existing.height == height;
    }

    /// Evict the oldest stored images (lowest `seq`) until the store fits
    /// the budget. Never evicts `protect_id` (the one just touched).
    fn evictStoreForBudget(self: *Manager, protect_id: u32) void {
        if (self.budget_bytes == 0) return;
        while (self.store_bytes > self.budget_bytes) {
            var victim: ?u32 = null;
            var lowest: u64 = std.math.maxInt(u64);
            var it = self.store.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* == protect_id) continue;
                if (e.value_ptr.seq < lowest) {
                    lowest = e.value_ptr.seq;
                    victim = e.key_ptr.*;
                }
            }
            const vid = victim orelse break; // only the protected one left
            if (self.store.fetchRemove(vid)) |entry| {
                var sv = entry.value;
                self.freeStoredImage(&sv);
            }
        }
    }

    /// Ingest a kitty graphics command. Returns:
    ///   - .none: nothing to do (chunk accumulated, query, etc.)
    ///   - .place: caller should place stored image_id at cursor
    pub const Outcome = struct {
        action: enum { none, place },
        /// Playback metadata changed or a frame made an image animated.
        /// The renderer must re-evaluate its continuous tick before the
        /// next frame-clock callback.
        animation_changed: bool = false,
        image_id: u32,
        placement_id: u32,
        z: i32,
        /// When >0, scale the placed image to this many cells.
        /// 0 = render at native pixel size.
        cells_wide: u32 = 0,
        cells_high: u32 = 0,
        /// Source-rect crop (image-pixel coords). w_or_h == 0 means
        /// "use the whole image".
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
    };

    pub fn ingest(self: *Manager, cmd: kitty.Command) Outcome {
        const default = Outcome{
            .action = .none,
            .image_id = cmd.image_id,
            .placement_id = cmd.placement_id,
            .z = cmd.z,
        };

        // Resolve effective image_id: continuation chunks may omit
        // `i=` (per kitty spec) — route to whichever transmission is
        // currently in flight.
        var effective_id = cmd.image_id;
        if (effective_id == 0 and self.active_transmit_id != 0) {
            effective_id = self.active_transmit_id;
        }

        // Continuation chunks omit `a=` too — when an accumulator
        // already exists for this id, treat .unknown as "continue".
        var effective = cmd.action;
        if (effective == .unknown and self.accums.contains(effective_id)) {
            effective = .transmit_and_place; // will be overridden below
        }

        // Animation control: a=a — pure metadata, no payload to
        // accumulate.
        if (effective == .animate) {
            self.applyAnimateControl(cmd);
            var outcome = default;
            outcome.animation_changed = true;
            return outcome;
        }

        switch (effective) {
            .place => {
                // a=p — place an existing image at the cursor.
                if (self.store.contains(cmd.image_id)) {
                    return .{
                        .action = .place,
                        .image_id = cmd.image_id,
                        .placement_id = cmd.placement_id,
                        .z = cmd.z,
                        .cells_wide = cmd.cells_wide,
                        .cells_high = cmd.cells_high,
                        .src_x = cmd.src_x,
                        .src_y = cmd.src_y,
                        .src_w = cmd.src_w,
                        .src_h = cmd.src_h,
                    };
                }
                return default;
            },
            .transmit, .transmit_and_place, .transmit_frame => {
                // Chunked transfer: appended into accum until m=0.
                const is_first = !self.accums.contains(effective_id);
                if (is_first and self.accums.count() >= MAX_ACCUMS) {
                    // Too many in-flight transmissions never finalized — a
                    // misbehaving stream. Refuse new ones rather than letting
                    // the accum table grow without bound.
                    return default;
                }
                if (is_first) {
                    // Treat the original cmd.action as the source of
                    // truth for what to do on finalize. .unknown can
                    // only happen for continuation chunks (handled
                    // above), so this is the FIRST chunk.
                    self.accums.put(effective_id, .{
                        .format = if (cmd.format == 0) 32 else cmd.format,
                        .width = cmd.width,
                        .height = cmd.height,
                        .medium = cmd.medium,
                        .compression = cmd.compression,
                        .data_size = cmd.data_size,
                        .action = cmd.action,
                        // Frame-only metadata (z=delay, c=target frame,
                        // r=compose source, C=compose mode). Stored
                        // unconditionally — finalize ignores when
                        // action != .transmit_frame.
                        .frame_delay_ms = if (cmd.z >= 0) @intCast(cmd.z) else 0,
                        .frame_target = cmd.cells_wide,
                        .frame_compose_from = cmd.cells_high,
                        .frame_compose_mode = cmd.no_cursor_move,
                        .number = cmd.image_number,
                    }) catch return default;
                    self.active_transmit_id = effective_id;
                }
                if (self.accums.getPtr(effective_id)) |acc| {
                    // Cap the in-flight payload: an unterminated `m=1` chunk
                    // stream would otherwise grow one accumulator without
                    // bound. Past the cap, poison it (finalize bails) and drop
                    // the buffer so the memory is reclaimed immediately.
                    const payload_len = std.math.add(usize, acc.payload.items.len, cmd.payload.len) catch std.math.maxInt(usize);
                    if (payload_len > self.accumCap()) {
                        acc.poisoned = true;
                        acc.payload.clearAndFree(self.allocator);
                    } else if (!acc.poisoned) {
                        acc.payload.appendSlice(self.allocator, cmd.payload) catch {
                            acc.poisoned = true;
                        };
                    }
                    if (cmd.more == 1) return default; // wait for more
                }
                // Capture the original action BEFORE finalize drops the accum.
                const original_action: kitty.Action = if (self.accums.getPtr(effective_id)) |a| a.action else effective;
                // m=0 (or absent) — finalize.
                const stored_ok = self.finalize(effective_id) catch false;
                if (self.active_transmit_id == effective_id) self.active_transmit_id = 0;
                if (!stored_ok) return default;

                if (original_action == .transmit_and_place) {
                    return .{
                        .action = .place,
                        .image_id = effective_id,
                        .placement_id = cmd.placement_id,
                        .z = cmd.z,
                        .cells_wide = cmd.cells_wide,
                        .cells_high = cmd.cells_high,
                        .src_x = cmd.src_x,
                        .src_y = cmd.src_y,
                        .src_w = cmd.src_w,
                        .src_h = cmd.src_h,
                    };
                }
                if (original_action == .transmit_frame) {
                    var outcome = default;
                    outcome.animation_changed = true;
                    return outcome;
                }
                return default;
            },
            else => return default,
        }
    }

    /// Drop a stored image (called from delete dispatch).
    pub fn drop(self: *Manager, image_id: u32) void {
        if (self.store.fetchRemove(image_id)) |entry| {
            var v = entry.value;
            self.freeStoredImage(&v);
        }
        if (self.accums.fetchRemove(image_id)) |entry| {
            var v = entry.value;
            v.deinit(self.allocator);
        }
        // Avoid stale active_transmit_id if we just yanked the
        // in-flight transmission out from under it.
        if (self.active_transmit_id == image_id) self.active_transmit_id = 0;
    }

    pub fn dropAll(self: *Manager) void {
        var it = self.store.iterator();
        while (it.next()) |e| self.freeStoredImage(e.value_ptr);
        self.store.clearRetainingCapacity();
        var ait = self.accums.iterator();
        while (ait.next()) |e| e.value_ptr.deinit(self.allocator);
        self.accums.clearRetainingCapacity();
        self.active_transmit_id = 0;
    }

    /// Drop every image the client tagged with this number (`d=N`).
    /// A number can be reused across ids, so this is not a single
    /// lookup.
    pub fn dropByNumber(self: *Manager, number: u32) void {
        if (number == 0) return;
        var doomed: [32]u32 = undefined;
        var n: usize = 0;
        var it = self.store.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.number != number) continue;
            if (n == doomed.len) break;
            doomed[n] = e.key_ptr.*;
            n += 1;
        }
        for (doomed[0..n]) |id| self.drop(id);
    }

    /// Drop every image whose id falls in an inclusive range (`d=R`).
    pub fn dropRange(self: *Manager, lo: u32, hi: u32) void {
        if (hi < lo) return;
        var doomed: [64]u32 = undefined;
        var n: usize = 0;
        var it = self.store.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            if (id < lo or id > hi) continue;
            if (n == doomed.len) break;
            doomed[n] = id;
            n += 1;
        }
        for (doomed[0..n]) |id| self.drop(id);
    }

    /// The number a stored image was transmitted with, or 0.
    pub fn numberOf(self: *Manager, image_id: u32) u32 {
        const img = self.store.get(image_id) orelse return 0;
        return img.number;
    }

    /// Look up a stored image's RGBA + dims.
    pub fn get(self: *Manager, image_id: u32) ?StoredImage {
        return self.store.get(image_id);
    }

    /// Report a dropped transfer under `--debug-images` and return false.
    /// Every rejection in `finalize` goes through this: a silently
    /// discarded image is indistinguishable from a renderer bug.
    fn reject(
        self: *const Manager,
        image_id: u32,
        comptime reason: []const u8,
        args: anytype,
    ) bool {
        if (self.debug) std.debug.print(
            "[kitty] dropping image id={d}: " ++ reason ++ "\n",
            .{image_id} ++ args,
        );
        return false;
    }

    /// Decode the accumulated payload for `image_id`, store it, drop
    /// the accumulator. Returns true if a usable image was stored.
    fn finalize(self: *Manager, image_id: u32) !bool {
        var entry = self.accums.fetchRemove(image_id) orelse return false;
        defer entry.value.deinit(self.allocator);
        const acc = &entry.value;

        // Bail early on a poisoned accumulator: an appendSlice failed
        // mid-chunk-stream so the payload is truncated. Decoding it
        // would silently produce a corrupt image.
        if (acc.poisoned) {
            return self.reject(image_id, "poisoned chunk stream (OOM during append)", .{});
        }

        if (acc.compression > 1)
            return self.reject(image_id, "unsupported compression o={d}", .{acc.compression});
        const raw_layout: ?RawLayout = switch (acc.format) {
            24, 32 => rawLayout(acc.format, acc.width, acc.height) orelse
                return self.reject(
                    image_id,
                    "{d}x{d} f={d} is not a decodable size (0, overflow, or past the {d}B ceiling)",
                    .{ acc.width, acc.height, acc.format, image_size.max_decoded_bytes },
                ),
            100 => null,
            else => return self.reject(image_id, "unsupported format f={d}", .{acc.format}),
        };
        if (raw_layout != null and !self.frameTargetValid(image_id, acc, acc.width, acc.height))
            return self.reject(image_id, "a=f frame does not match a stored {d}x{d} image", .{ acc.width, acc.height });

        // Strip whitespace/newlines in place so finalization does not retain a
        // second attacker-sized copy of the encoded transfer.
        var stripped_len: usize = 0;
        for (acc.payload.items) |b| {
            if (b == ' ' or b == '\n' or b == '\r' or b == '\t') continue;
            acc.payload.items[stripped_len] = b;
            stripped_len += 1;
        }
        acc.payload.items.len = stripped_len;
        if (acc.payload.items.len == 0) return self.reject(image_id, "empty payload", .{});

        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(acc.payload.items) catch
            return self.reject(image_id, "payload is not valid base64 ({d}B)", .{acc.payload.items.len});
        if (acc.medium == 'd' and acc.compression == 0) {
            if (raw_layout) |layout| if (out_len != layout.input_bytes)
                return self.reject(
                    image_id,
                    "payload decodes to {d}B, {d}x{d} f={d} needs {d}B",
                    .{ out_len, acc.width, acc.height, acc.format, layout.input_bytes },
                );
        }
        const decoded = try self.allocator.alloc(u8, out_len);
        defer self.allocator.free(decoded);
        decoder.decode(decoded, acc.payload.items) catch
            return self.reject(image_id, "base64 decode failed", .{});

        // For tempfile / file medium: payload (post-base64) is a path.
        var raw_bytes: []const u8 = decoded;
        var owned_file_data: ?[]u8 = null;
        defer if (owned_file_data) |b| self.allocator.free(b);
        if (acc.medium == 't' or acc.medium == 'f') {
            const path = std.mem.trimEnd(u8, decoded, "\x00 \r\n\t");
            const data = self.readFile(path) catch
                return self.reject(image_id, "cannot read t=/f= file '{s}'", .{path});
            owned_file_data = data;
            raw_bytes = data;
            if (acc.medium == 't') {
                // Zig 0.16's std.fs.deleteFileAbsolute is gone — use libc.
                var del_z: [4096]u8 = undefined;
                if (path.len < del_z.len) {
                    @memcpy(del_z[0..path.len], path);
                    del_z[path.len] = 0;
                    if (c.unlink(@ptrCast(&del_z)) != 0) {
                        std.debug.print("sketerm: failed to delete kitty tempfile {s}\n", .{path});
                    }
                }
            }
        }

        // Optional zlib decompression (`o=z`). Raw formats have an exact
        // length from dimensions; compressed PNG requires `S=` by protocol.
        var owned_inflated: ?[]u8 = null;
        defer if (owned_inflated) |b| self.allocator.free(b);
        if (acc.compression == 1) {
            const inflated_len = if (raw_layout) |layout|
                layout.input_bytes
            else blk: {
                if (acc.data_size == 0)
                    return self.reject(image_id, "compressed PNG without S= (size unknown)", .{});
                break :blk @as(usize, acc.data_size);
            };
            if (inflated_len > image_size.max_decoded_bytes)
                return self.reject(
                    image_id,
                    "inflated size {d}B is past the {d}B ceiling",
                    .{ inflated_len, image_size.max_decoded_bytes },
                );
            const inflated = try self.allocator.alloc(u8, inflated_len);
            owned_inflated = inflated;
            if (!inflateExact(raw_bytes, inflated))
                return self.reject(image_id, "zlib payload does not inflate to exactly {d}B", .{inflated_len});
            raw_bytes = inflated;
        }

        // Decode according to format.
        const stored: StoredImage = switch (acc.format) {
            32 => blk: {
                const need = raw_layout.?.rgba_bytes;
                if (raw_bytes.len != need)
                    return self.reject(image_id, "RGBA payload is {d}B, need {d}B", .{ raw_bytes.len, need });
                const out = if (owned_inflated) |inflated| take: {
                    owned_inflated = null;
                    break :take inflated;
                } else try self.allocator.dupe(u8, raw_bytes);
                break :blk .{ .rgba = out, .width = acc.width, .height = acc.height };
            },
            24 => blk: {
                const layout = raw_layout.?;
                if (raw_bytes.len != layout.input_bytes)
                    return self.reject(image_id, "RGB payload is {d}B, need {d}B", .{ raw_bytes.len, layout.input_bytes });
                const out = try self.allocator.alloc(u8, layout.rgba_bytes);
                var i: usize = 0;
                while (i < layout.pixels) : (i += 1) {
                    out[i * 4 + 0] = raw_bytes[i * 3 + 0];
                    out[i * 4 + 1] = raw_bytes[i * 3 + 1];
                    out[i * 4 + 2] = raw_bytes[i * 3 + 2];
                    out[i * 4 + 3] = 0xFF;
                }
                break :blk .{ .rgba = out, .width = acc.width, .height = acc.height };
            },
            100 => blk: {
                if (raw_bytes.len > std.math.maxInt(c_int))
                    return self.reject(image_id, "PNG payload of {d}B is too large to decode", .{raw_bytes.len});
                var info_w: c_int = 0;
                var info_h: c_int = 0;
                var info_ch: c_int = 0;
                if (c.stbi_info_from_memory(
                    raw_bytes.ptr,
                    @intCast(raw_bytes.len),
                    &info_w,
                    &info_h,
                    &info_ch,
                ) == 0 or info_w <= 0 or info_h <= 0 or info_ch <= 0 or info_ch > 4)
                    return self.reject(image_id, "PNG header is unreadable ({d}B payload)", .{raw_bytes.len});
                const png_w: u32 = @intCast(info_w);
                const png_h: u32 = @intCast(info_h);
                const need = image_size.byteLen(png_w, png_h, 4) catch |err|
                    return self.reject(image_id, "PNG {d}x{d}: {s}", .{ png_w, png_h, @errorName(err) });
                if (!self.frameTargetValid(image_id, acc, png_w, png_h))
                    return self.reject(image_id, "a=f PNG frame does not match a stored {d}x{d} image", .{ png_w, png_h });

                var w: c_int = 0;
                var h: c_int = 0;
                var ch: c_int = 0;
                const pix = c.stbi_load_from_memory(
                    raw_bytes.ptr,
                    @intCast(raw_bytes.len),
                    &w,
                    &h,
                    &ch,
                    4,
                );
                if (pix == null or w != info_w or h != info_h or ch != info_ch)
                    return self.reject(
                        image_id,
                        "PNG decode failed or changed metadata ({d}B payload)",
                        .{raw_bytes.len},
                    );
                defer c.stbi_image_free(pix);
                const out = try self.allocator.alloc(u8, need);
                @memcpy(out, pix[0..need]);
                break :blk .{
                    .rgba = out,
                    .width = png_w,
                    .height = png_h,
                };
            },
            else => return self.reject(image_id, "unsupported format f={d}", .{acc.format}),
        };

        // Frame-data action: append (or compose into) the existing
        // animation. The decoded `stored.rgba` becomes a new Frame.
        if (acc.action == .transmit_frame) {
            return self.appendFrame(image_id, stored, acc) catch false;
        }

        // Replace any prior image with this id.
        if (self.store.fetchRemove(image_id)) |old| {
            var v = old.value;
            self.freeStoredImage(&v);
        }
        var with_number = stored;
        with_number.number = acc.number;
        try self.insertStored(image_id, with_number);
        return true;
    }

    /// Append a frame to an existing image's animation. Promotes a
    /// static image into an animation on first call (frames[] becomes
    /// non-empty; rgba aliases frames[0].rgba).
    fn appendFrame(self: *Manager, image_id: u32, new_frame: StoredImage, acc: *const Accum) !bool {
        const existing = self.store.getPtr(image_id) orelse {
            // No source image; treat as a regular store.
            self.allocator.free(new_frame.rgba);
            return self.reject(image_id, "a=f frame for an image that was never transmitted", .{});
        };
        // Frames must match dimensions of the source.
        if (new_frame.width != existing.width or new_frame.height != existing.height) {
            self.allocator.free(new_frame.rgba);
            return self.reject(
                image_id,
                "a=f frame is {d}x{d}, the image is {d}x{d}",
                .{ new_frame.width, new_frame.height, existing.width, existing.height },
            );
        }

        // Snapshot the image's byte footprint so we can apply the net delta
        // (promote / compose / append / replace / frame-cap) to store_bytes
        // in one place rather than tracking each branch.
        const before_bytes = existing.storedBytes();

        // Promote: if static, move existing rgba into frames[0].
        if (existing.frames.items.len == 0) {
            try existing.frames.append(self.allocator, .{
                .rgba = existing.rgba,
                .delay_ms = 100,
            });
            // existing.rgba now aliases frames[0].rgba (don't double-free).
        }

        // Composition: per kitty spec, when `C=0` (default) the new
        // frame is alpha-blended over the base frame (referenced by
        // `r=` or the previous frame); `C=1` overwrites.
        const compose_alpha = acc.frame_compose_mode == 0;
        const have_base = existing.frames.items.len > 0;
        if (compose_alpha and have_base) {
            const base_idx: usize = blk: {
                if (acc.frame_compose_from > 0 and acc.frame_compose_from <= existing.frames.items.len) {
                    break :blk acc.frame_compose_from - 1;
                }
                break :blk existing.frames.items.len - 1;
            };
            const base = existing.frames.items[base_idx].rgba;
            // In-place: blend new_frame.rgba over base, write back into
            // new_frame.rgba (which we own and will install).
            const npix: usize = @as(usize, existing.width) * @as(usize, existing.height);
            var p: usize = 0;
            while (p < npix) : (p += 1) {
                const i = p * 4;
                const a: u32 = new_frame.rgba[i + 3];
                if (a == 0xFF) continue; // fully opaque — keep new
                if (a == 0) {
                    // Fully transparent — copy base.
                    new_frame.rgba[i + 0] = base[i + 0];
                    new_frame.rgba[i + 1] = base[i + 1];
                    new_frame.rgba[i + 2] = base[i + 2];
                    new_frame.rgba[i + 3] = base[i + 3];
                    continue;
                }
                const inv: u32 = 255 - a;
                inline for (0..3) |k| {
                    const n: u32 = new_frame.rgba[i + k];
                    const b: u32 = base[i + k];
                    new_frame.rgba[i + k] = @intCast((n * a + b * inv + 127) / 255);
                }
                // Output alpha = 1 - (1-a_new)(1-a_base). Saturate.
                const ab: u32 = base[i + 3];
                new_frame.rgba[i + 3] = @intCast(255 - ((255 - a) * (255 - ab) / 255));
            }
        }

        // Insert / append frame.
        const target = acc.frame_target;
        if (target == 0 or target > existing.frames.items.len) {
            // Append at end.
            try existing.frames.append(self.allocator, .{
                .rgba = new_frame.rgba,
                .delay_ms = if (acc.frame_delay_ms == 0) 100 else acc.frame_delay_ms,
            });
        } else {
            // Replace the existing 1-based frame at index `target - 1`.
            const idx: usize = target - 1;
            self.allocator.free(existing.frames.items[idx].rgba);
            existing.frames.items[idx] = .{
                .rgba = new_frame.rgba,
                .delay_ms = if (acc.frame_delay_ms == 0) 100 else acc.frame_delay_ms,
            };
        }
        // Cap frame count: drop oldest frames so one runaway `a=f` loop on a
        // fixed id can't grow without bound.
        while (existing.frames.items.len > MAX_FRAMES) {
            const dropped = existing.frames.orderedRemove(0);
            self.allocator.free(dropped.rgba);
            if (existing.current_frame > 0) existing.current_frame -= 1;
        }
        // Re-anchor `existing.rgba` to the current frame in case the
        // insertion replaced it (clamp in case the cap shifted indices).
        if (existing.current_frame >= existing.frames.items.len) {
            existing.current_frame = @intCast(existing.frames.items.len - 1);
        }
        existing.rgba = existing.frames.items[existing.current_frame].rgba;
        existing.generation +%= 1;

        // Apply the net byte delta and evict other images if over budget.
        const after_bytes = existing.storedBytes();
        self.store_bytes = self.store_bytes - @min(self.store_bytes, before_bytes) + after_bytes;
        self.evictStoreForBudget(image_id);
        return true;
    }

    fn applyAnimateControl(self: *Manager, cmd: kitty.Command) void {
        const img = self.store.getPtr(cmd.image_id) orelse return;
        // Per kitty spec a=a fields:
        //   c — playback state (1=stop, 2=run, 3=loading)
        //   r — number of loops (0 = infinite)
        //   s — set current frame
        // Our parser stored c in cells_wide, r in cells_high, s in width.
        const play_state = cmd.cells_wide;
        const loop_count = cmd.cells_high;
        const set_frame = cmd.width;
        switch (play_state) {
            1 => img.playing = false,
            2 => img.playing = true,
            else => {},
        }
        if (loop_count > 0) img.loops_remaining = @intCast(loop_count);
        if (set_frame > 0 and img.frames.items.len > 0) {
            const idx = @min(set_frame - 1, img.frames.items.len - 1);
            img.current_frame = @intCast(idx);
            img.rgba = img.frames.items[idx].rgba;
            img.generation +%= 1;
        }
    }

    /// Advance every animated image's current_frame based on elapsed
    /// time. Called from a tick callback. Returns true if any image
    /// changed frame (caller should refresh placements).
    pub fn advanceAnimations(self: *Manager, now_us: i64) bool {
        var any_advanced = false;
        var it = self.store.iterator();
        while (it.next()) |entry| {
            const img = entry.value_ptr;
            if (img.frames.items.len < 2) continue;
            if (!img.playing) continue;
            if (img.last_advance_us < 0) {
                img.last_advance_us = now_us;
                continue;
            }
            const delay_us: i64 = @as(i64, @intCast(img.frames.items[img.current_frame].delay_ms)) * 1000;
            if (now_us - img.last_advance_us < delay_us) continue;

            // Advance frame, accounting for loop wrap.
            const next: u32 = (img.current_frame + 1) % @as(u32, @intCast(img.frames.items.len));
            if (next == 0 and img.loops_remaining > 0) {
                img.loops_remaining -= 1;
                if (img.loops_remaining == 0) {
                    img.playing = false;
                    img.last_advance_us = now_us;
                    continue;
                }
            }
            img.current_frame = next;
            img.rgba = img.frames.items[next].rgba;
            img.last_advance_us = now_us;
            img.generation +%= 1;
            any_advanced = true;
        }
        return any_advanced;
    }

    fn readFile(self: *Manager, path: []const u8) ![]u8 {
        // Zig 0.16's `std.fs.openFileAbsolute` now needs an `Io`. We
        // link libc, so use it directly.
        var path_z: [4096]u8 = undefined;
        const p = pathZ(&path_z, path) catch return error.BadFile;
        const fp = c.fopen(p, "rb") orelse return error.BadFile;
        defer _ = c.fclose(fp);
        if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.BadFile;
        const size_long = c.ftell(fp);
        if (size_long <= 0) return error.BadFile;
        const max: c_long = 64 * 1024 * 1024; // sanity cap
        if (size_long > max) return error.BadFile;
        if (c.fseek(fp, 0, c.SEEK_SET) != 0) return error.BadFile;
        const size: usize = @intCast(size_long);
        const buf = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buf);
        const n = c.fread(buf.ptr, 1, size, fp);
        if (n != size) return error.ShortRead;
        return buf;
    }
};

const testBase64 = @import("../util/b64.zig").encodeAlloc;

fn testZlibBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const compressed_buf = try allocator.alloc(u8, bytes.len + 128);
    defer allocator.free(compressed_buf);
    var writer = std.Io.Writer.fixed(compressed_buf);
    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&writer, &window, .zlib, .fastest);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    return testBase64(allocator, writer.buffered());
}

test "manager handles single-chunk RGBA transmit_and_place" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Build a 2×2 RGBA payload base64-encoded.
    var rgba: [16]u8 = undefined;
    @memset(&rgba, 0xAA);
    var b64_buf: [32]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const b64 = enc.encode(&b64_buf, &rgba);

    const cmd = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 7,
        .format = 32,
        .width = 2,
        .height = 2,
        .more = 0,
        .payload = b64,
    };
    const out = mgr.ingest(cmd);
    try std.testing.expectEqual(@as(u32, 7), out.image_id);
    const stored = mgr.get(7).?;
    try std.testing.expectEqual(@as(u32, 2), stored.width);
    try std.testing.expectEqual(@as(u32, 2), stored.height);
    try std.testing.expectEqual(@as(usize, 16), stored.rgba.len);
}

test "manager accumulates multi-chunk PNG" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Tiny 1×1 red PNG (89 50 4E 47 ...). Smallest possible PNG.
    const tiny_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x5A, 0xD2, 0x18,
        0xF8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    var b64_buf: [256]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const b64 = enc.encode(&b64_buf, &tiny_png);
    // Split base64 in two roughly even halves.
    const mid = b64.len / 2;

    const c1 = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 9,
        .format = 100,
        .more = 1,
        .payload = b64[0..mid],
    };
    const c2 = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 9,
        .more = 0,
        .payload = b64[mid..],
    };
    const out1 = mgr.ingest(c1);
    try std.testing.expectEqual(@as(@TypeOf(out1.action), .none), out1.action);
    const out2 = mgr.ingest(c2);
    try std.testing.expectEqual(@as(u32, 9), out2.image_id);
    const stored = mgr.get(9) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 1), stored.width);
    try std.testing.expectEqual(@as(u32, 1), stored.height);

    // Compressed PNG is valid when S= declares the exact inflated PNG size.
    const compressed = try testZlibBase64(std.testing.allocator, &tiny_png);
    defer std.testing.allocator.free(compressed);
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 10,
        .format = 100,
        .compression = 1,
        .data_size = tiny_png.len,
        .payload = compressed,
    });
    try std.testing.expect(mgr.get(10) != null);

    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 11,
        .format = 100,
        .compression = 1,
        .data_size = tiny_png.len - 1,
        .payload = compressed,
    });
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 12,
        .format = 100,
        .compression = 1,
        .payload = compressed,
    });
    try std.testing.expect(mgr.get(11) == null);
    try std.testing.expect(mgr.get(12) == null);
}

test "manager accepts chunked zlib RGB and RGBA images" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const rgba = [_]u8{
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
        0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0xFF,
    };
    const rgba_b64 = try testZlibBase64(std.testing.allocator, &rgba);
    defer std.testing.allocator.free(rgba_b64);
    const mid = rgba_b64.len / 2;
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 20,
        .format = 32,
        .width = 2,
        .height = 2,
        .compression = 1,
        .more = 1,
        .payload = rgba_b64[0..mid],
    });
    _ = mgr.ingest(.{ .image_id = 0, .more = 0, .payload = rgba_b64[mid..] });
    try std.testing.expectEqualSlices(u8, &rgba, mgr.get(20).?.rgba);

    const rgb = [_]u8{ 0x01, 0x02, 0x03, 0x11, 0x12, 0x13 };
    const rgb_b64 = try testZlibBase64(std.testing.allocator, &rgb);
    defer std.testing.allocator.free(rgb_b64);
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 21,
        .format = 24,
        .width = 2,
        .height = 1,
        .compression = 1,
        .payload = rgb_b64,
    });
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0xFF, 0x11, 0x12, 0x13, 0xFF }, mgr.get(21).?.rgba);
}

test "manager rejects invalid and overflowing raw dimensions" {
    try std.testing.expectError(image_size.Error.InvalidDimensions, image_size.byteLen(0, 1, 4));
    try std.testing.expectError(
        image_size.Error.TooLarge,
        image_size.byteLen(std.math.maxInt(u32), std.math.maxInt(u32), 4),
    );

    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    const payload = "AAAAAA==";
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 30,
        .format = 32,
        .width = 0,
        .height = 1,
        .payload = payload,
    });
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 32,
        .format = 32,
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
        .payload = payload,
    });
    try std.testing.expect(mgr.get(30) == null);
    try std.testing.expect(mgr.get(32) == null);
}

test "manager rejects short and long raw payloads" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    const bytes = [_]u8{0xA5} ** 17;
    const short = try testBase64(std.testing.allocator, bytes[0..15]);
    defer std.testing.allocator.free(short);
    const long = try testBase64(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(long);
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 40,
        .format = 32,
        .width = 2,
        .height = 2,
        .payload = short,
    });
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 41,
        .format = 32,
        .width = 2,
        .height = 2,
        .payload = long,
    });
    try std.testing.expect(mgr.get(40) == null);
    try std.testing.expect(mgr.get(41) == null);
}

test "manager rejects short and long zlib inflation" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    const bytes = [_]u8{0x5A} ** 17;
    const short = try testZlibBase64(std.testing.allocator, bytes[0..15]);
    defer std.testing.allocator.free(short);
    const long = try testZlibBase64(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(long);
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 50,
        .format = 32,
        .width = 2,
        .height = 2,
        .compression = 1,
        .payload = short,
    });
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 51,
        .format = 32,
        .width = 2,
        .height = 2,
        .compression = 1,
        .payload = long,
    });
    try std.testing.expect(mgr.get(50) == null);
    try std.testing.expect(mgr.get(51) == null);
}

test "manager bounds high-ratio zlib inflation to metadata size" {
    var bomb: [64 * 1024]u8 = undefined;
    @memset(&bomb, 0);
    const payload = try testZlibBase64(std.testing.allocator, &bomb);
    defer std.testing.allocator.free(payload);

    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 60,
        .format = 32,
        .width = 1,
        .height = 1,
        .compression = 1,
        .payload = payload,
    });
    try std.testing.expect(mgr.get(60) == null);
}

test "the configured budget evicts, it never rejects" {
    const rgba = [_]u8{0xCC} ** 16;
    const payload = try testBase64(std.testing.allocator, &rgba);
    defer std.testing.allocator.free(payload);

    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.budget_bytes = rgba.len;
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 70,
        .format = 32,
        .width = 2,
        .height = 2,
        .payload = payload,
    });
    try std.testing.expect(mgr.get(70) != null);

    // An animation frame that does not fit the budget must still be
    // appended — the budget is answered by evicting OTHER images.
    _ = mgr.ingest(.{
        .action = .transmit_frame,
        .image_id = 70,
        .format = 32,
        .width = 2,
        .height = 2,
        .payload = payload,
    });
    try std.testing.expectEqual(@as(usize, 2), mgr.get(70).?.frames.items.len);

    // A whole image larger than the budget still stores: `icat` on a big
    // screenshot with a low image_memory_mb must not render nothing.
    var undersized = Manager.init(std.testing.allocator);
    defer undersized.deinit();
    undersized.budget_bytes = rgba.len - 1;
    _ = undersized.ingest(.{
        .action = .transmit,
        .image_id = 71,
        .format = 32,
        .width = 2,
        .height = 2,
        .payload = payload,
    });
    try std.testing.expect(undersized.get(71) != null);

    // ...and the OLDEST is evicted when a second one arrives.
    var fifo = Manager.init(std.testing.allocator);
    defer fifo.deinit();
    fifo.budget_bytes = rgba.len;
    for ([_]u32{ 80, 81 }) |id| {
        _ = fifo.ingest(.{
            .action = .transmit,
            .image_id = id,
            .format = 32,
            .width = 2,
            .height = 2,
            .payload = payload,
        });
    }
    try std.testing.expect(fifo.get(80) == null);
    try std.testing.expect(fifo.get(81) != null);
    try std.testing.expectEqual(rgba.len, fifo.store_bytes);
}

test "a wide strip decodes: only total bytes bound an image" {
    // 20000x2 RGBA = 160KB. One axis is past max_dimension; the total is
    // trivial. GL_MAX_TEXTURE_SIZE is handled at upload, not at decode.
    const w: u32 = 20000;
    const h: u32 = 2;
    const rgba = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(rgba);
    @memset(rgba, 0x40);
    const payload = try testBase64(std.testing.allocator, rgba);
    defer std.testing.allocator.free(payload);

    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 90,
        .format = 32,
        .width = w,
        .height = h,
        .payload = payload,
    });
    const stored = mgr.get(90) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(w, stored.width);
    try std.testing.expectEqual(h, stored.height);
}

test "manager: a=p before any transmit returns none" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    const cmd = kitty.Command{ .action = .place, .image_id = 99, .placement_id = 1 };
    const out = mgr.ingest(cmd);
    try std.testing.expectEqual(@as(u32, 99), out.image_id);
    // .none — caller doesn't place when nothing stored.
}

test "animation: a=f appends a frame" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Initial transmit (a=t).
    var rgba_a: [16]u8 = undefined;
    @memset(&rgba_a, 0xAA);
    var b64a: [32]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const bA = enc.encode(&b64a, &rgba_a);
    const cmd_t = kitty.Command{
        .action = .transmit,
        .image_id = 5,
        .format = 32,
        .width = 2,
        .height = 2,
        .more = 0,
        .payload = bA,
    };
    _ = mgr.ingest(cmd_t);

    // Append a 2nd frame (a=f). z=200 ms delay.
    var rgba_b: [16]u8 = undefined;
    @memset(&rgba_b, 0x55);
    var b64b: [32]u8 = undefined;
    const bB = enc.encode(&b64b, &rgba_b);
    const cmd_f = kitty.Command{
        .action = .transmit_frame,
        .image_id = 5,
        .format = 32,
        .width = 2,
        .height = 2,
        .more = 0,
        .payload = bB,
        .z = 200,
    };
    const frame_outcome = mgr.ingest(cmd_f);
    try std.testing.expect(frame_outcome.animation_changed);

    const stored = mgr.store.getPtr(5).?;
    try std.testing.expectEqual(@as(usize, 2), stored.frames.items.len);
    try std.testing.expectEqual(@as(u32, 200), stored.frames.items[1].delay_ms);
}

test "animation: advanceAnimations cycles current_frame" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Build an animation with 3 frames manually.
    const a0 = try std.testing.allocator.dupe(u8, "AAAAAAAAAAAAAAAA");
    const a1 = try std.testing.allocator.dupe(u8, "BBBBBBBBBBBBBBBB");
    const a2 = try std.testing.allocator.dupe(u8, "CCCCCCCCCCCCCCCC");
    var img: StoredImage = .{ .rgba = a0, .width = 2, .height = 2 };
    try img.frames.append(std.testing.allocator, .{ .rgba = a0, .delay_ms = 50 });
    try img.frames.append(std.testing.allocator, .{ .rgba = a1, .delay_ms = 50 });
    try img.frames.append(std.testing.allocator, .{ .rgba = a2, .delay_ms = 50 });
    try mgr.store.put(7, img);

    // First call seeds `last_advance_us`.
    _ = mgr.advanceAnimations(0);
    // 50 ms = 50_000 us — should advance.
    const advanced1 = mgr.advanceAnimations(50_000);
    try std.testing.expect(advanced1);
    try std.testing.expectEqual(@as(u32, 1), mgr.store.getPtr(7).?.current_frame);
    // Another 50 ms → frame 2.
    const advanced2 = mgr.advanceAnimations(100_000);
    try std.testing.expect(advanced2);
    try std.testing.expectEqual(@as(u32, 2), mgr.store.getPtr(7).?.current_frame);
    // Wrap → frame 0.
    const advanced3 = mgr.advanceAnimations(150_000);
    try std.testing.expect(advanced3);
    try std.testing.expectEqual(@as(u32, 0), mgr.store.getPtr(7).?.current_frame);
}

test "animation: a=f with C=0 alpha-blends transparent over base" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Base frame: solid red 1x1 RGBA.
    const base = [_]u8{ 0xFF, 0x00, 0x00, 0xFF };
    var b64a: [8]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const bA = enc.encode(&b64a, &base);
    _ = mgr.ingest(.{
        .action = .transmit,
        .image_id = 11,
        .format = 32,
        .width = 1,
        .height = 1,
        .more = 0,
        .payload = bA,
    });

    // Add frame with full transparency (alpha=0). C=0 (alpha-blend)
    // should keep base pixel; C=1 (overwrite) would replace.
    const transparent = [_]u8{ 0x00, 0xFF, 0x00, 0x00 };
    var b64b: [8]u8 = undefined;
    const bB = enc.encode(&b64b, &transparent);
    _ = mgr.ingest(.{
        .action = .transmit_frame,
        .image_id = 11,
        .format = 32,
        .width = 1,
        .height = 1,
        .more = 0,
        .payload = bB,
        .no_cursor_move = 0, // C=0 → alpha blend
    });

    const stored = mgr.store.getPtr(11).?;
    try std.testing.expectEqual(@as(usize, 2), stored.frames.items.len);
    // Frame 1 should be the base (red), since the new frame was fully
    // transparent and we composed alpha=0 over the base.
    try std.testing.expectEqual(@as(u8, 0xFF), stored.frames.items[1].rgba[0]);
    try std.testing.expectEqual(@as(u8, 0x00), stored.frames.items[1].rgba[1]);
}

test "animation: a=a stop pauses playback" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const a0 = try std.testing.allocator.dupe(u8, "AAAAAAAAAAAAAAAA");
    const a1 = try std.testing.allocator.dupe(u8, "BBBBBBBBBBBBBBBB");
    var img: StoredImage = .{ .rgba = a0, .width = 2, .height = 2 };
    try img.frames.append(std.testing.allocator, .{ .rgba = a0, .delay_ms = 50 });
    try img.frames.append(std.testing.allocator, .{ .rgba = a1, .delay_ms = 50 });
    try mgr.store.put(8, img);

    // Stop via a=a, c=1.
    const stop_cmd = kitty.Command{ .action = .animate, .image_id = 8, .cells_wide = 1 };
    const stop_outcome = mgr.ingest(stop_cmd);
    try std.testing.expect(stop_outcome.animation_changed);
    try std.testing.expect(!mgr.store.getPtr(8).?.playing);

    // advanceAnimations does nothing when not playing.
    _ = mgr.advanceAnimations(0);
    _ = mgr.advanceAnimations(1_000_000);
    try std.testing.expectEqual(@as(u32, 0), mgr.store.getPtr(8).?.current_frame);

    // Re-run via a=a, c=2.
    const run_cmd = kitty.Command{ .action = .animate, .image_id = 8, .cells_wide = 2 };
    const run_outcome = mgr.ingest(run_cmd);
    try std.testing.expect(run_outcome.animation_changed);
    try std.testing.expect(mgr.store.getPtr(8).?.playing);
}

test "store budget evicts oldest images and bounds store_bytes" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.budget_bytes = 64 * 3; // room for exactly three 4x4 images
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const rgba = try std.testing.allocator.alloc(u8, 64);
        @memset(rgba, 0);
        try mgr.insertStored(i + 1, .{ .rgba = rgba, .width = 4, .height = 4 });
    }
    try std.testing.expect(mgr.store_bytes <= mgr.budget_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 3), mgr.store_bytes);
    try std.testing.expectEqual(@as(u32, 3), mgr.store.count());
    // Newest survives; oldest evicted.
    try std.testing.expect(mgr.store.contains(10));
    try std.testing.expect(!mgr.store.contains(1));
}

test "unterminated chunked transmission is capped, not unbounded" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    // The cap follows the hard ceiling, not `budget_bytes` — a small
    // configured budget must not make a legitimate transfer impossible.
    mgr.budget_bytes = 1024;
    const cap = mgr.accumCap();
    try std.testing.expect(cap > mgr.budget_bytes);
    const chunk = [_]u8{'A'} ** 512;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = mgr.ingest(.{ .action = .transmit, .image_id = 1, .payload = &chunk, .more = 1 });
    }
    const acc = mgr.accums.getPtr(1).?;
    // Well under the cap: nothing poisoned, nothing dropped.
    try std.testing.expect(!acc.poisoned);
    try std.testing.expectEqual(@as(usize, 100 * chunk.len), acc.payload.items.len);
}

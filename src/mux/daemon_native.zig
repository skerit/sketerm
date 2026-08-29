//! Native Wayland app pipe — per-channel unit parsing, brain relay,
//! backlog gating, seat-intent filtering, clipboard/dnd transfers —
//! split out of daemon.zig. Functions take the owning *Daemon and are
//! aliased back into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const wltrack = @import("../wlhost/track.zig");
const wlpipe = @import("../wlhost/pipe.zig");
const wlwire = @import("../wlhost/wire.zig");
const dmabuf = @import("../wlhost/dmabuf.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Session = dmod.Session;
const Channel = dmod.Channel;
const Native = dmod.Native;
const nowMs = @import("../util/clock.zig").nowMs;
const dmabuf_egl = @import("dmabuf_egl.zig");
const wlproto = @import("../wlhost/protocol.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const nativeViewer = Daemon.nativeViewer;
const isController = Daemon.isController;
const build_options = @import("build_options");
const wlpixcodec = @import("../wlhost/pixcodec.zig");
const subscribedAudioViewer = Daemon.subscribedAudioViewer;

// ── sketerm-native app pipe ─────────────────────────────────

/// Drain the app's Wayland socket: bytes into the reassembly
/// buffer, SCM_RIGHTS fds into the pairing queue, then process
/// complete messages.
pub fn nativeReadable(self: *Daemon, ch: *Channel) void {
    const nv = ch.native.?;
    var rounds: u8 = 0;
    while (rounds < 4) : (rounds += 1) {
        var data: [16384]u8 = undefined;
        var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
        var iov = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        mh.msg_control = &cbuf;
        mh.msg_controllen = cbuf.len;
        // No MSG_CMSG_CLOEXEC: Darwin lacks it, and the daemon
        // is single-threaded — collectFds sets FD_CLOEXEC before
        // anything can fork.
        const r = c.recvmsg(ch.fd, &mh, 0);
        if (r < 0) {
            if (std.posix.errno(r) != .AGAIN) self.closeChannel(ch, true);
            break;
        }
        if (r == 0) {
            self.closeChannel(ch, true);
            break;
        }
        collectFds(nv, &mh);
        nv.inbuf.appendSlice(nv.allocator, data[0..@intCast(r)]) catch {
            self.closeChannel(ch, true);
            return;
        };
        if (@as(usize, @intCast(r)) < data.len) break;
    }
    if (!ch.dead) nativeProcess(self, ch);
}

/// Hand-rolled CMSG walk (the CMSG_* macros don't survive
/// translate-c). On both 64-bit glibc and musl the cmsghdr is 16
/// bytes and CMSG_ALIGN(sizeof cmsghdr) == sizeof cmsghdr, so
/// data follows the header directly.
pub fn collectFds(nv: *Native, mh: *const c.struct_msghdr) void {
    const ctl: [*]const u8 = @ptrCast(mh.msg_control orelse return);
    const clen: usize = @intCast(mh.msg_controllen);
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    const alignment: usize = @sizeOf(usize);
    var off: usize = 0;
    while (off + hdr_size <= clen) {
        const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(ctl + off));
        const cl: usize = @intCast(hdr.cmsg_len);
        if (cl < hdr_size or off + cl > clen) break;
        if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
            const n_fds = (cl - hdr_size) / @sizeOf(c_int);
            var i: usize = 0;
            while (i < n_fds) : (i += 1) {
                var fd: c_int = undefined;
                @memcpy(std.mem.asBytes(&fd), ctl[off + hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)]);
                _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
                nv.fds.append(nv.allocator, fd) catch {
                    _ = c.close(fd);
                };
            }
        }
        off += (cl + alignment - 1) & ~(alignment - 1);
    }
}

/// Peel complete Wayland messages off the reassembly buffer,
/// track them, and emit pipe units toward the GUI. Any protocol
/// violation kills the app connection (matching a strict
/// compositor).
pub fn nativeProcess(self: *Daemon, ch: *Channel) void {
    const nv = ch.native.?;
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(self.allocator);
    // The brain's copy of the request stream: wl_msg units only —
    // its View has no frame callback, so pool bytes would be
    // allocated and decoded for nothing.
    var brain_in: std.ArrayList(u8) = .empty;
    defer brain_in.deinit(self.allocator);

    var pos: usize = 0;
    var fail = false;
    var close_after_flush = false;
    while (!fail and !close_after_flush) {
        const avail = nv.inbuf.items[pos..];
        const mh = wlwire.parseHeader(avail) catch {
            fail = true;
            break;
        } orelse break;
        if (avail.len < mh.size) break;
        const msgb = avail[0..mh.size];
        // Descriptors this request is entitled to, resolved BEFORE the
        // tracker runs (a destructor request unregisters its object).
        const declared_fds = requestFdCount(nv, mh);
        const held_fds = nv.fds.items.len;
        const action = nv.tracker.clientMessage(mh, msgb[wlwire.header_size..]) catch |err| {
            const iname = if (nv.tracker.objects.get(mh.object)) |i| i.name else "?";
            log.warn("killing wayland app connection: {s} on {s}#{d} opcode {d} (session '{s}')", .{ @errorName(err), iname, mh.object, mh.opcode, if (ch.session) |s| s.name else "?" });
            fail = true;
            break;
        };
        nativeAction(self, nv, &units, msgb, action) catch |err| {
            if (err == error.CloseAfterFlush)
                close_after_flush = true
            else
                fail = true;
            break;
        };
        // Every request whose signature carries an 'h' has an action
        // arm that pops exactly that many descriptors. A new arm that
        // forgets would strand one fd per call in `nv.fds` — a slow
        // fd-table leak that ends in the daemon, so it fails closed
        // here instead of drifting.
        if (!fdPairingHolds(declared_fds, held_fds, nv.fds.items.len)) {
            log.warn("killing wayland app connection: {d} fd(s) declared, {d} consumed on {s}#{d} opcode {d} (session '{s}')", .{
                declared_fds,
                held_fds -| nv.fds.items.len,
                if (nv.tracker.objects.get(mh.object)) |i| i.name else "?",
                mh.object,
                mh.opcode,
                if (ch.session) |s| s.name else "?",
            });
            fail = true;
            break;
        }
        wlpipe.appendUnit(&brain_in, self.allocator, .wl_msg, msgb) catch {
            fail = true;
            break;
        };
        pos += mh.size;
    }
    if (pos > 0) {
        const rem = nv.inbuf.items.len - pos;
        std.mem.copyForwards(u8, nv.inbuf.items[0..rem], nv.inbuf.items[pos..]);
        nv.inbuf.shrinkRetainingCapacity(rem);
    }
    // Every complete message above took the descriptors its signature
    // declares, so what is left is owed to messages the client has not
    // finished sending. A handful is normal (see MAX_PENDING_FDS); a
    // growing pile is a client sending descriptors nothing will ever
    // consume, and it ends with the daemon out of file descriptors.
    if (!fail and !close_after_flush and nv.fds.items.len > MAX_PENDING_FDS) {
        log.warn("killing wayland app connection: {d} unpaired SCM_RIGHTS fds held (session '{s}')", .{
            nv.fds.items.len,
            if (ch.session) |s| s.name else "?",
        });
        fail = true;
    }
    if (!fail and !close_after_flush and brain_in.items.len > 0) {
        nv.brain.now_ms = @truncate(@as(u64, @intCast(nowMs())));
        nv.brain.feed(brain_in.items) catch {
            fail = true;
        };
        // The app bound linux-dmabuf at v4 or created a feedback
        // object: pre-v8 replicas cap the global at 3 and lack
        // the feedback interface, so either request is fatal to
        // them — stop shipping this session's app channels
        // there. Keyed on the app's requests, not on the
        // advertisement: announcing v4 costs old viewers nothing
        // until an app actually binds it.
        if (nv.brain.used_dmabuf_feedback) {
            if (ch.session) |s|
                s.native_state_min = @max(s.native_state_min, wire.DMABUF_FEEDBACK_STATE_VERSION);
        }
        // Likewise for the post-v8 core requests.
        if (nv.brain.used_post_v8_request) {
            if (ch.session) |s|
                s.native_state_min = @max(s.native_state_min, wire.CORE_BUMP_STATE_VERSION);
        }
        // ... and for xdg-foreign, whose interfaces a v9 replica's
        // protocol tables do not contain at all.
        if (nv.brain.used_foreign) {
            if (ch.session) |s|
                s.native_state_min = @max(s.native_state_min, wire.FOREIGN_STATE_VERSION);
        }
        // ... and for xdg-dialog, one version later again.
        if (nv.brain.used_dialog) {
            if (ch.session) |s|
                s.native_state_min = @max(s.native_state_min, wire.DIALOG_STATE_VERSION);
        }
        flushBrain(self, ch);
    }
    if (units.items.len > 0 and !ch.dead) queueUnits(self, ch, units.items);
    if (fail) self.closeChannel(ch, true);
    if (close_after_flush and !ch.dead) self.channelWritable(ch);
}

/// Flush every brain holding output after an xdg-foreign teardown
/// queued events on a connection other than the one being fed. That
/// client may be idle for minutes, so its `destroyed` cannot wait for
/// its own next request.
pub fn flushPendingBrains(self: *Daemon) void {
    if (!self.foreign_flush_pending) return;
    self.foreign_flush_pending = false;
    for (self.channels.items) |ch| {
        if (ch.dead) continue;
        const nv = ch.native orelse continue;
        if (nv.brain.out.items.len > 0) flushBrain(self, ch);
    }
}

/// Apply the brain's queued output (events toward the app,
/// keymap/clip side-band) and close the channel on a brain-fatal
/// protocol error.
pub fn flushBrain(self: *Daemon, ch: *Channel) void {
    const nv = ch.native.?;
    const out = nv.brain.takeOut();
    if (out.len > 0) {
        var pos: usize = 0;
        while (wlpipe.peelUnit(out[pos..]) catch null) |p| {
            applyAppUnit(self, ch, p.unit.tag, p.unit.payload);
            if (ch.dead) break;
            pos += p.consumed;
        }
    }
    nv.brain.clearOut();
    if (nv.brain.dead and !ch.dead) self.closeChannel(ch, true);
}

/// Bound on pool bytes per pipe unit — also the granularity at
/// which queueUnits may split the stream into chan_data frames.
pub const POOL_CHUNK: usize = 1 << 20;

/// Queues wl_display.error against `object`: the protocol-defined
/// fatal outcome for a request the compositor refuses. The channel
/// closes only after the client can read it, so the app learns WHY
/// instead of seeing a bare hangup — and the refusal costs this one
/// connection, never the daemon that owns every other session.
pub fn queueProtocolError(nv: *Native, object: u32, code: u32, message: []const u8) !void {
    const ch = nv.chan orelse return error.NoChannel;
    var buf: [128]u8 = undefined;
    var b = wlwire.Builder.init(&buf, 1, 0); // wl_display.error
    b.putObject(object);
    b.putUint(code);
    b.putString(message);
    try ch.pending.appendSlice(ch.allocator, try b.finish());
    ch.close_after_flush = true;
}

/// wl_shm.error.invalid_fd -- what a compositor answers when a client's
/// shm fd cannot back the pool it declared.
const SHM_INVALID_FD: u32 = 2;

/// Whether `fd` currently backs at least `need` bytes; an fd that
/// cannot be stat'd fails closed. This is the FAST refusal for a
/// client that lies about its pool size, not the safety boundary: a
/// client can still ftruncate the object smaller after the check. The
/// boundary is that the daemon never maps client memory at all (see
/// `mapMirror` / `pullPoolRows`), so a shrunk pool costs that app its
/// connection instead of costing every session a SIGBUS. Checked
/// against the CURRENT size because a pool legitimately grows: the
/// client ftruncates before it resizes.
fn fdBacksBytes(fd: c_int, need: usize) bool {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return false;
    if (st.st_size < 0) return false;
    return @as(u64, @intCast(st.st_size)) >= @as(u64, need);
}

/// Daemon-owned backing store for a pool mirror: anonymous memory the
/// client cannot shrink, truncate or unmap, so no page the daemon ever
/// touches belongs to the app. The client's bytes are copied in with
/// `pread` at commit time. A shared mapping of the client's fd would
/// be zero-copy, but every read of it is a SIGBUS the app controls,
/// and that signal kills the daemon -- every session of the user,
/// local and remote -- not just the app that lied.
fn mapMirror(size: usize) ?[*]u8 {
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANON, -1, 0);
    if (ptr == null or ptr == c.MAP_FAILED) return null;
    return @ptrCast(ptr.?);
}

/// Copies `len` bytes at `off` of the pool's fd into the mirror; a
/// short read means the client shrank the object under its own
/// buffers, which is the protocol violation the mapping used to turn
/// into a fault.
fn pullPoolRows(fd: c_int, mirror: [*]u8, off: usize, len: usize) error{ PoolShrunk, ReadFailed }!void {
    var done: usize = 0;
    while (done < len) {
        const n = c.pread(fd, mirror + off + done, len - done, @intCast(off + done));
        if (n == 0) return error.PoolShrunk;
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        done += @intCast(n);
    }
}

/// Object a message is addressed to; wl_display when the header does
/// not parse, which the caller has already ruled out.
fn msgObject(msgb: []const u8) u32 {
    const hdr = (wlwire.parseHeader(msgb) catch null) orelse return 1;
    return hdr.object;
}

/// Descriptors this request's signature declares, so the drain loop can
/// hold every action arm to the pairing contract. Zero for an unknown
/// object or opcode — the tracker refuses those itself.
fn requestFdCount(nv: *const Native, hdr: wlwire.Header) u32 {
    const iface = nv.tracker.objects.get(hdr.object) orelse return 0;
    if (hdr.opcode >= iface.requests.len) return 0;
    return wlproto.fdCount(iface.requests[hdr.opcode].sig);
}

/// Ceiling on SCM_RIGHTS descriptors held with no message to pair them
/// with. It cannot be zero: fds are paired in arrival order and one may
/// legitimately precede the bytes of the message that consumes it
/// (libwayland flushes its out queue the moment 28 descriptors are
/// pending, written request or not), so `nativeProcess` checks what is
/// left AFTER every complete message has taken what its signature
/// declares. Anything still held then belongs to a message the client
/// has not finished sending, and a backlog past this is a violation:
/// unbounded, it exhausts the daemon's fd table and kills every session.
pub const MAX_PENDING_FDS: usize = 128;

/// The pairing contract one processed request must satisfy: it took
/// from the SCM_RIGHTS queue exactly the descriptors its signature
/// declares, no more (a double pop strands the next request) and no
/// fewer (a forgotten pop leaks one fd per call).
fn fdPairingHolds(declared: u32, held_before: usize, held_after: usize) bool {
    return held_after + @as(usize, declared) == held_before;
}

pub fn nativeAction(self: *Daemon, nv: *Native, units: *std.ArrayList(u8), msgb: []const u8, action: wltrack.Action) !void {
    const a = self.allocator;
    switch (action) {
        .relay => try wlpipe.appendUnit(units, a, .wl_msg, msgb),
        .buffer_create => |bc| {
            if (nv.pools.getPtr(bc.pool)) |m| m.buffers += 1;
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .buffer_destroy => |bd| {
            if (nv.dmabufs.fetchRemove(bd.id)) |kv| {
                var mirror = kv.value;
                mirror.deinit();
            } else if (nv.tracker.buffers.get(bd.id)) |info| {
                // Last buffer of an already-destroyed shm pool:
                // the mirror is finally reclaimable. The buffer's
                // incarnation serial decides WHICH mirror it
                // releases — the current holder of the pool id,
                // or a displaced (orphaned) predecessor.
                if (!info.dmabuf) {
                    const cur = nv.pools.getPtr(info.pool);
                    if (cur != null and cur.?.serial == info.serial) {
                        const m = cur.?;
                        if (m.buffers > 0) m.buffers -= 1;
                        if (m.destroyed and m.buffers == 0)
                            try nv.reclaimPool(units, a, info.pool);
                    } else {
                        nv.releaseOrphan(info.serial);
                    }
                }
            }
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .surface_destroy => |sd| {
            if (nv.vstate.fetchRemove(sd.id)) |kv| {
                var vs = kv.value;
                vs.deinit();
            }
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .dmabuf_add => |da| {
            // The fd rides the same SCM_RIGHTS queue as create_pool;
            // every add consumes exactly one descriptor in arrival order.
            const fd = nv.popFd() orelse return error.MissingFd;
            if (da.plane >= dmabuf.MAX_PLANES) {
                _ = c.close(fd);
                return error.BadPlane;
            }
            const gop = nv.dmabuf_pending.getOrPut(a, da.params) catch {
                _ = c.close(fd);
                return error.OutOfMemory;
            };
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const slot = &gop.value_ptr.fds[@intCast(da.plane)];
            if (slot.* >= 0) {
                _ = c.close(fd);
                return error.DuplicatePlane;
            }
            slot.* = fd;
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .dmabuf_create_failed => |dcf| {
            // Non-immed create: the brain answers `failed` (client
            // falls back to shm); drop every pending plane.
            if (nv.dmabuf_pending.fetchRemove(dcf.params)) |kv| {
                var pending = kv.value;
                pending.deinit();
            }
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .params_destroy => |pd| {
            if (nv.dmabuf_pending.fetchRemove(pd.id)) |kv| {
                var pending = kv.value;
                pending.deinit();
            }
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .dmabuf_create => |dc| {
            const kv = nv.dmabuf_pending.fetchRemove(dc.params) orelse return error.MissingFd;
            var pending = kv.value;
            defer pending.deinit();
            if (nv.dmabufs.contains(dc.id)) return error.PoolIdCollision;
            if (pending.fds[0] < 0) return error.MissingFd;

            var source_size: ?u64 = null;
            for (0..dc.info.plane_count) |plane_index| {
                const source_fd = pending.fds[plane_index];
                if (source_fd < 0) return error.MissingFd;
                var source_stat: c.struct_stat = undefined;
                if (c.fstat(source_fd, &source_stat) == 0 and source_stat.st_size > 0) {
                    const size: u64 = @intCast(source_stat.st_size);
                    if (plane_index == 0) source_size = size;
                    if (size < dc.info.required_sizes[plane_index]) {
                        try queueProtocolError(nv, dc.params, 6, "dma-buf plane is out of bounds");
                        return error.CloseAfterFlush;
                    }
                }
            }
            if (source_size) |size| {
                if (size < dc.info.required_size) {
                    try queueProtocolError(nv, dc.params, 6, "dma-buf plane is out of bounds");
                    return error.CloseAfterFlush;
                }
            }

            // A destroyed wl_shm_pool may retain storage for its old
            // buffers after delete_id made the numeric id reusable.
            if (nv.pools.getPtr(dc.id)) |old| {
                if (old.buffers > 0) {
                    try nv.orphan_pools.put(a, old.serial, old.*);
                } else {
                    old.unmap();
                }
                _ = nv.pools.remove(dc.id);
            }

            const tight_stride = std.math.mul(usize, dc.info.width, 4) catch return error.BadSize;
            const staging_size = std.math.mul(usize, tight_stride, dc.info.height) catch return error.BadSize;
            const staging = try a.alloc(u8, staging_size);
            @memset(staging, 0);
            var mirror = Native.DmabufMirror{
                .allocator = a,
                .source_fds = pending.takeFds(),
                .staging = staging,
                .width = dc.info.width,
                .height = dc.info.height,
                .offset = dc.info.plane.offset,
                .stride = dc.info.plane.stride,
                .flags = dc.info.flags,
            };
            var installed = false;
            defer if (!installed) mirror.deinit();

            if (dc.info.plane.modifier == dmabuf.DRM_FORMAT_MOD_LINEAR) {
                if (source_size != null) {
                    const map_size: usize = @intCast(dc.info.required_size);
                    const ptr = c.mmap(null, map_size, c.PROT_READ, c.MAP_SHARED, mirror.source_fds[0], 0);
                    if (ptr != null and ptr != c.MAP_FAILED)
                        mirror.linear = .{ .ptr = @ptrCast(ptr.?), .size = map_size };
                }
            }

            if (mirror.linear == null) {
                const importer = nv.dmabuf_importer orelse {
                    try queueProtocolError(nv, dc.params, 7, "dma-buf import failed");
                    return error.CloseAfterFlush;
                };
                var planes: [dmabuf.MAX_PLANES]dmabuf_egl.Plane = undefined;
                for (0..dc.info.plane_count) |plane_index| {
                    const plane = dc.info.planes[plane_index].?;
                    planes[plane_index] = .{
                        .fd = mirror.source_fds[plane_index],
                        .offset = plane.offset,
                        .stride = plane.stride,
                        .modifier = plane.modifier,
                    };
                }
                mirror.imported = importer.importBuffer(.{
                    .width = dc.info.width,
                    .height = dc.info.height,
                    .format = dc.info.format,
                    .flags = dc.info.flags,
                    .planes = planes[0..dc.info.plane_count],
                }) orelse {
                    try queueProtocolError(nv, dc.params, 7, "dma-buf import failed");
                    return error.CloseAfterFlush;
                };
                log.debug("dmabuf buffer {d}: EGL modifier import active (modifier=0x{x})", .{ dc.id, dc.info.plane.modifier });
            } else {
                log.debug("dmabuf buffer {d}: LINEAR mmap active", .{dc.id});
            }

            try nv.dmabufs.put(a, dc.id, mirror);
            installed = true;
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .clip_receive => |cr| {
            // App wants to paste: hold the write-end (tagged with
            // the offer id) until the GUI ships clip_data — or a
            // dnd transfer claims it by offer.
            const fd = nv.popFd() orelse return error.MissingFd;
            nv.clip_paste_fds.append(a, .{ .offer = cr.offer, .fd = fd }) catch {
                _ = c.close(fd);
                return error.MissingFd;
            };
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .primary_receive => {
            // Primary paste: same dance, separate FIFO.
            const fd = nv.popFd() orelse return error.MissingFd;
            nv.primary_paste_fds.append(a, fd) catch {
                _ = c.close(fd);
                return error.MissingFd;
            };
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
        .pool_create => |p| {
            const fd = nv.popFd() orelse return error.MissingFd;
            errdefer _ = c.close(fd);
            if (nv.dmabufs.contains(p.id)) return error.PoolIdCollision;
            if (p.size <= 0) return error.BadSize;
            const sz: usize = @intCast(p.size);
            if (!fdBacksBytes(fd, sz)) {
                // Refused BEFORE the mmap and before any pipe unit:
                // no mirror exists and no replica has heard of this
                // pool, so there is nothing to retire — the errdefer
                // above closes the fd and the app connection dies
                // alone with a protocol error it can read.
                try queueProtocolError(nv, msgObject(msgb), SHM_INVALID_FD, "shm pool larger than its backing file");
                return error.CloseAfterFlush;
            }
            const ptr = mapMirror(sz) orelse return error.MapFailed;
            // munmap before close on the failure path, matching the
            // teardown order in Native.deinit (errdefers run LIFO,
            // and the fd's close errdefer was registered earlier).
            // Emit the pipe units FIRST so the only remaining
            // fallible step is pools.put: once put succeeds the map
            // owns the mapping (deinit frees it) and this errdefer
            // no longer fires.
            errdefer _ = c.munmap(@ptrCast(ptr), sz);
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            try wlpipe.appendPoolMeta(units, a, .pool_create, p.id, @intCast(sz));
            // Replicas adopt the tracker's incarnation serial so
            // serial-addressed units resolve on mid-session
            // attaches (their self-counted serials diverge).
            try wlpipe.appendPoolSerial(units, a, p.id, p.serial);
            const gop = try nv.pools.getOrPut(a, p.id);
            if (gop.found_existing) {
                // Recycled pool id (delete_id reuse). Old buffers
                // may still reference the displaced mirror — park
                // it under its serial until the last one dies;
                // with no referents, free it now or it leaks one
                // full-pool mmap per recycle.
                if (gop.value_ptr.buffers > 0) {
                    log.debug("pool {d}: id recycled, orphaning serial={d} ({d} buffer refs)", .{ p.id, gop.value_ptr.serial, gop.value_ptr.buffers });
                    nv.orphan_pools.put(a, gop.value_ptr.serial, gop.value_ptr.*) catch gop.value_ptr.unmap();
                } else {
                    gop.value_ptr.unmap();
                }
            }
            gop.value_ptr.* = .{ .fd = fd, .ptr = ptr, .size = sz, .serial = p.serial };
            log.debug("pool {d} mirrored size={d} serial={d}", .{ p.id, sz, p.serial });
        },
        .pool_resize => |p| {
            const mirror = nv.pools.getPtr(p.id) orelse return error.NoSuchPool;
            if (p.size <= 0) return error.BadSize;
            const sz: usize = @intCast(p.size);
            if (sz < mirror.size) return error.BadSize; // pools only grow
            if (!fdBacksBytes(mirror.fd, sz)) {
                // Checked before the munmap, so the refusal leaves the
                // mirror exactly as the last good size left it: its
                // buffers keep resolving and the channel teardown is
                // still the one thing that unmaps it.
                try queueProtocolError(nv, p.id, SHM_INVALID_FD, "shm pool resized past its backing file");
                return error.CloseAfterFlush;
            }
            // The mirror is daemon memory, so growing it is a copy into
            // a larger anonymous mapping: existing buffers keep their
            // committed pixels and only the tail is new. The old
            // mapping is released only once the new one exists, so a
            // failed grow leaves the pool exactly as it was.
            const ptr = mapMirror(sz) orelse return error.MapFailed;
            @memcpy(ptr[0..mirror.size], mirror.ptr[0..mirror.size]);
            _ = c.munmap(mirror.ptr, mirror.size);
            mirror.ptr = ptr;
            mirror.size = sz;
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            try wlpipe.appendPoolMeta(units, a, .pool_resize, p.id, @intCast(sz));
        },
        .pool_destroy => |pd| {
            // Reclaim now if no buffer references the pool memory;
            // otherwise mark it and reclaim on the last
            // buffer_destroy (wl_shm_pool destructor semantics).
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            if (nv.pools.getPtr(pd.id)) |m| {
                if (m.buffers == 0) {
                    log.debug("pool {d} destroyed: mirror reclaimed", .{pd.id});
                    try nv.reclaimPool(units, a, pd.id);
                } else {
                    log.debug("pool {d} destroyed: reclaim deferred ({d} buffer refs)", .{ pd.id, m.buffers });
                    m.destroyed = true;
                }
            }
        },
        .commit => |cm| {
            // A dmabuf is safe to reread only when this commit consumes
            // a new attach. After release, a no-attach commit cannot
            // authorize access to storage the producer may have reused.
            if (cm.info.dmabuf and !cm.attached_now) {
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
                return;
            }
            // Capture every dmabuf before the request reaches the
            // brain: commit may immediately produce wl_buffer.release,
            // after which the producer may overwrite the source.
            var dmabuf_mirror: ?*Native.DmabufMirror = null;
            if (cm.info.dmabuf) {
                const mirror = nv.dmabufs.getPtr(cm.buffer) orelse return error.NoSuchBuffer;
                mirror.capture(&nv.dmabuf_scratch) catch |err| {
                    // A successfully-created wl_buffer must not become a
                    // protocol error after a later import/readback failure.
                    // Keep its last capture and still commit/release it.
                    log.warn("dmabuf buffer {d}: capture failed ({s}); retaining previous pixels", .{ cm.buffer, @errorName(err) });
                };
                dmabuf_mirror = mirror;
            }

            // shm: pull the committed rows from the client's fd into the
            // daemon-owned mirror BEFORE anything reads it, viewer or
            // no viewer -- the mirror is what a reattaching replica and
            // the video path read, so it must be current after every
            // commit, not only after shipped ones. The first commit of
            // a buffer pulls its whole region: rows outside the declared
            // damage are still this buffer's content and a replay ships
            // them. Later commits pull the damaged rows only, the same
            // rows a shared mapping would have shown changed.
            if (!cm.info.dmabuf and cm.info.offset >= 0 and cm.info.stride > 0 and cm.info.height > 0) {
                const shm: ?Native.PoolMirror = blk: {
                    if (nv.pools.get(cm.info.pool)) |m| {
                        if (m.serial == cm.info.serial) break :blk m;
                    }
                    break :blk nv.orphan_pools.get(cm.info.serial);
                };
                if (shm) |m| {
                    const first = if (nv.tracker.buffers.getPtr(cm.buffer)) |b| !b.pulled else true;
                    var py0: i64 = 0;
                    var py1: i64 = cm.info.height;
                    if (!first) {
                        if (cm.damage) |d| {
                            py0 = @max(py0, @as(i64, d.y0));
                            py1 = @min(py1, @as(i64, d.y1));
                        }
                    }
                    if (py0 < py1) {
                        const off: usize = @intCast(@as(i64, cm.info.offset) + py0 * cm.info.stride);
                        const len: usize = @intCast((py1 - py0) * cm.info.stride);
                        const end = @min(off +| len, m.size);
                        if (off < end) {
                            pullPoolRows(m.fd, m.ptr, off, end - off) catch |err| {
                                // The client shrank (or closed) the object
                                // under a buffer it just committed. With a
                                // shared mapping this was the SIGBUS; now it
                                // is this app's protocol error.
                                log.warn("pool {d}: {s} pulling committed rows (session '{s}')", .{
                                    cm.info.pool,
                                    @errorName(err),
                                    if (nv.chan) |chan| (if (chan.session) |s| s.name else "?") else "?",
                                });
                                try queueProtocolError(nv, cm.info.pool, SHM_INVALID_FD, "shm pool shrank under a committed buffer");
                                return error.CloseAfterFlush;
                            };
                        }
                    }
                    if (nv.tracker.buffers.getPtr(cm.buffer)) |b| b.pulled = true;
                }
            }

            // Copy the damaged rows (full buffer when the client
            // never declares damage). Rows are contiguous in shm;
            // dmabufs expose the same layout through tight staging.
            //
            // Skip the whole pixel copy+encode when no client is
            // watching this session: the units would be dropped by
            // queueUnits anyway, and a reattaching viewer gets the
            // committed mirror re-encoded by replayNativeChannels. Saves
            // a headless daemon (MCP running an animated app) from
            // burning CPU zstd-encoding frames for nobody.
            //
            // pool_update_c addresses pools by ID, so only commits
            // against the pool id's CURRENT incarnation ship that
            // way; a buffer from a displaced (orphaned) incarnation
            // — a client that keeps committing old-pool storage
            // across a recreate, like Wine's DirectDraw on a mode
            // switch — ships SERIAL-addressed (pool_update_s) from
            // the orphan mirror, which holds the live bytes.
            var pix_state: u8 = 1; // shipping
            var orphan_route = false;
            const mirror_opt: ?Native.PixelMirror = blk: {
                if (!self.hasNativeViewer(nv)) {
                    pix_state = 2;
                    break :blk null;
                }
                if (cm.info.dmabuf) {
                    const m = dmabuf_mirror.?;
                    break :blk .{ .ptr = m.staging.ptr, .size = m.staging.len };
                }
                if (nv.pools.get(cm.info.pool)) |m| {
                    if (m.serial == cm.info.serial) break :blk .{ .ptr = m.ptr, .size = m.size, .shm = m };
                }
                if (nv.orphan_pools.get(cm.info.serial)) |m| {
                    pix_state = 3;
                    orphan_route = true;
                    break :blk .{ .ptr = m.ptr, .size = m.size, .shm = m };
                }
                pix_state = 4;
                break :blk null;
            };
            // Log transitions, not frames — state 4 is the "app
            // renders but nothing ships, silently" failure class.
            if (pix_state != nv.pix_state) {
                nv.pix_state = pix_state;
                switch (pix_state) {
                    1 => log.debug("commit pixels: shipping (surface {d}, pool {d})", .{ cm.surface, cm.info.pool }),
                    2 => log.debug("commit pixels: skipped, no attached viewer (mirror stays current for reattach)", .{}),
                    3 => log.debug("commit pixels: buffer {d} is orphan-backed — shipping serial-addressed (serial={d})", .{ cm.buffer, cm.info.serial }),
                    4 => log.warn("commit resolves NO mirror ({s} {d}, session '{s}') — window will not update", .{
                        if (cm.info.dmabuf) "dmabuf buffer" else "pool",
                        if (cm.info.dmabuf) cm.buffer else cm.info.pool,
                        if (nv.chan) |chan| (if (chan.session) |s| s.name else "?") else "?",
                    }),
                    else => {},
                }
            }
            if (pix_state == 2) {
                // Pixels skipped with a viewer set to recover:
                // remember the missed rows so the next SHIPPED
                // commit re-covers them (regions the app never
                // re-damages would otherwise stay stale forever).
                const gop = nv.skipped.getOrPut(a, cm.surface) catch null;
                if (gop) |g| {
                    g.value_ptr.* = if (g.found_existing)
                        wltrack.RowRange.mergeOpt(g.value_ptr.*, cm.damage)
                    else
                        cm.damage;
                }
            }
            if (mirror_opt) |mirror| {
                if (cm.info.offset >= 0 and cm.info.stride > 0 and cm.info.height > 0) {
                    var eff_damage = cm.damage;
                    if (nv.skipped.fetchRemove(cm.surface)) |kv|
                        eff_damage = wltrack.RowRange.mergeOpt(eff_damage, kv.value);
                    var y0: i64 = 0;
                    var y1: i64 = cm.info.height;
                    if (eff_damage) |d| {
                        y0 = @max(y0, @as(i64, d.y0));
                        y1 = @min(y1, @as(i64, d.y1));
                    }
                    if (y0 < y1) {
                        // A hot + photographic surface routes through the
                        // lossy video coder (pool_vtile) instead; the
                        // whole branch is comptime-off without -Dvideo, so
                        // default builds take the lossless path verbatim.
                        var did_video = false;
                        if (comptime build_options.video) {
                            // The video path is pool-id addressed;
                            // orphan and dmabuf commits stay lossless.
                            if (!cm.info.dmabuf and !orphan_route)
                                did_video = nv.videoCommit(units, a, cm, mirror.shm.?, y0, y1) catch false;
                        }
                        if (!did_video) {
                            // Chunk by WHOLE ROWS so each chunk starts at
                            // column 0 — the pixcodec predictor resets per
                            // row, and arbitrary byte cuts would misalign it.
                            const stride: usize = @intCast(cm.info.stride);
                            const rows_per_chunk: i64 = @intCast(@max(1, POOL_CHUNK / stride));
                            // Persistent scratch (reused every commit) — a
                            // per-commit local here leaked a frame-sized
                            // buffer per frame (the 15GB daemon: any
                            // continuously-rendering forwarded app).
                            const sc = &nv.pixscratch;
                            var y = y0;
                            while (y < y1) {
                                const yc = @min(y + rows_per_chunk, y1);
                                const off: usize = @intCast(@as(i64, cm.info.offset) + y * cm.info.stride);
                                const len: usize = @intCast((yc - y) * cm.info.stride);
                                const end = @min(off +| len, mirror.size);
                                if (off < end) {
                                    const raw = mirror.ptr[off..end];
                                    const enc = wlpixcodec.encodeRegion(sc, a, raw, stride) catch
                                        wlpixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = raw };
                                    if (orphan_route)
                                        try wlpipe.appendPoolUpdateS(units, a, cm.info.serial, @intCast(off), enc, @intCast(raw.len), @intCast(stride))
                                    else
                                        try wlpipe.appendPoolUpdateC(units, a, cm.info.pool, @intCast(off), enc, @intCast(raw.len), @intCast(stride));
                                }
                                y = yc;
                            }
                        }
                    }
                }
            }
            try wlpipe.appendUnit(units, a, .wl_msg, msgb);
        },
    }
}

/// Ship a unit stream to the channel's viewers, split into
/// chan_data frames well below MAX_FRAME (units may split across
/// frames — pipe.zig receivers reassemble). Native channels
/// broadcast to every attached proto>=6 client; winstream keeps
/// its 1:1 client.
pub fn queueUnits(self: *Daemon, ch: *Channel, bytes: []const u8) void {
    if (ch.native != null) {
        for (self.clients.items) |cl| {
            if (!nativeViewer(cl, ch.session.?)) continue;
            // An MCP client drains only during tool calls; past the
            // backlog cap, stop streaming entirely (a gap frame
            // marks it) — clientWritable rebuilds its replicas
            // from the live mirrors once it fully drains, which is
            // both bounded AND current, unlike a mile-long queue
            // of stale frames. GUI clients keep the stream: they
            // drain continuously and handle no mid-life replay.
            if (cl.kind == .mcp) {
                if (cl.needs_native_resync) continue;
                if (cl.wbuf.items.len > Daemon.MCP_NATIVE_BACKLOG) {
                    cl.needs_native_resync = true;
                    cl.queueFrame(.native_gap, "");
                    log.debug("mcp client over native backlog ({d}B queued) — pausing app frames until it drains", .{cl.wbuf.items.len});
                    continue;
                }
            }
            queueUnitsTo(self, cl, ch, bytes);
            // One unit run can itself blow past the cap (the app
            // committed a burst the daemon read in one batch) —
            // re-check AFTER queueing or the gap never triggers.
            if (cl.kind == .mcp and !cl.needs_native_resync and cl.wbuf.items.len > Daemon.MCP_NATIVE_BACKLOG) {
                cl.needs_native_resync = true;
                cl.queueFrame(.native_gap, "");
                log.debug("mcp client over native backlog ({d}B queued after burst) — pausing app frames until it drains", .{cl.wbuf.items.len});
            }
        }
    } else if (ch.pa != null) {
        // PCM only flows to viewers that SUBSCRIBED — terminal-only
        // clients and appdrive deliberately do not. Never drop PCM just
        // because graphical traffic filled the normal queue: consumed
        // reports bound production, and the priority lane drains audio
        // at the next frame boundary.
        for (self.clients.items) |cl| {
            if (subscribedAudioViewer(cl, ch.session.?))
                queueAudioUnitsTo(self, cl, ch, bytes);
        }
    } else if (ch.client) |cl| {
        if (!cl.dead) queueUnitsTo(self, cl, ch, bytes);
    }
}

pub fn queueUnitsTo(self: *Daemon, cl: *Client, ch: *Channel, bytes: []const u8) void {
    queueUnitsToLane(self, cl, ch, bytes, false);
}

pub fn queueAudioUnitsTo(self: *Daemon, cl: *Client, ch: *Channel, bytes: []const u8) void {
    queueUnitsToLane(self, cl, ch, bytes, true);
}

pub fn queueUnitsToLane(self: *Daemon, cl: *Client, ch: *Channel, bytes: []const u8, audio: bool) void {
    // Native units may split across frames. Keeping graphical frames
    // small gives the priority audio lane a frequent preemption point;
    // a 4 MiB frame can itself take seconds on a modest SSH link.
    const max_chunk: usize = if (audio or ch.native != null) 64 << 10 else 4 << 20;
    var off: usize = 0;
    while (off < bytes.len) {
        const end = @min(off + max_chunk, bytes.len);
        const payload = self.allocator.alloc(u8, 4 + (end - off)) catch {
            // Starving one viewer must not kill the app: drop the
            // client, keep the channel.
            cl.dead = true;
            return;
        };
        defer self.allocator.free(payload);
        std.mem.writeInt(u32, payload[0..4], ch.id, .little);
        @memcpy(payload[4..], bytes[off..end]);
        if (audio)
            cl.queueAudioFrame(.chan_data, payload)
        else
            cl.queueFrame(.chan_data, payload);
        off = end;
    }
}

/// One clipboard-fetch pipe is readable: drain it; on EOF ship
/// the collected bytes up as a clip_data unit and drop the
/// entry. Returns true when the entry was removed.
pub fn clipReadable(self: *Daemon, ch: *Channel, idx: usize) bool {
    const nv = ch.native.?;
    const cr = &nv.clip_reads.items[idx];
    var done = false;
    while (true) {
        var buf: [4096]u8 = undefined;
        const r = c.read(cr.fd, &buf, buf.len);
        if (r > 0) {
            // Cap pathological sources at 16 MB.
            if (cr.buf.items.len < (16 << 20)) {
                cr.buf.appendSlice(nv.allocator, buf[0..@intCast(r)]) catch {
                    done = true;
                    break;
                };
            }
            continue;
        }
        if (r < 0 and std.posix.errno(r) == .AGAIN) break;
        done = true; // EOF or error
        break;
    }
    if (!done) return false;
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(self.allocator);
    wlpipe.appendUnit(&units, self.allocator, .clip_data, cr.buf.items) catch {};
    if (units.items.len > 0) queueUnits(self, ch, units.items);
    _ = c.close(cr.fd);
    cr.buf.deinit(nv.allocator);
    _ = nv.clip_reads.orderedRemove(idx);
    return true;
}

/// Input-shaped viewer→brain units: only the session's CONTROLLER
/// may send these. `host_drop` is one of them — it synthesizes a
/// server-sourced drag-and-drop into the app, so a read-only viewer
/// dropping on a shared window would inject data through a window
/// whose every keystroke and click is discarded. Deliberately excludes
/// the data-transfer replies (clip_send/clip_data/primary_data/
/// drop_data) — those answer a request the DAEMON made of that
/// specific viewer, so gating them on the lease would hang the
/// initiator's clipboard, and the selection OFFERS
/// (offer_selection/offer_primary) plus set_scale, which are a viewer
/// describing ITSELF, not driving the app.
pub fn isSeatIntent(tag: wlpipe.Tag) bool {
    return viewerUnitKind(tag) == .intent;
}

/// What a unit means when a VIEWER sends it: the one declaring home
/// for the lease gate and for `nativeClientData`'s dispatch. `intent`
/// drives the app and is dropped from non-controllers; `describe` is a
/// viewer describing itself to the brain and is never gated;
/// `transfer` answers a daemon-initiated clipboard fetch or paste;
/// `daemon_only` is a tag viewers never legitimately send (daemon to
/// viewer, or brain-local), ignored. Exhaustive over every NAMED tag on
/// purpose: a new tag does not compile until it is classified here; an
/// unnamed wire value is `daemon_only`.
pub const ViewerUnit = enum { intent, describe, transfer, daemon_only };

pub fn viewerUnitKind(tag: wlpipe.Tag) ViewerUnit {
    return switch (tag) {
        .seat_enter,
        .seat_leave,
        .seat_motion,
        .seat_button,
        .seat_axis,
        .seat_kbd_enter,
        .seat_kbd_leave,
        .seat_key,
        .seat_mods,
        .configure,
        .dismiss_popups,
        .text_commit,
        .request_close,
        .host_drop,
        => .intent,
        .offer_selection,
        .offer_primary,
        .set_scale,
        => .describe,
        .clip_send,
        .clip_data,
        .primary_data,
        => .transfer,
        .wl_msg,
        .pool_create,
        .pool_update,
        .pool_resize,
        .pool_destroy,
        .keymap,
        .pool_update_z,
        .pool_update_c,
        .pool_vtile,
        .state_sync,
        .toplevel_icon,
        .dnd_send,
        .drop_data,
        .pool_serial,
        .pool_orphan,
        .pool_update_s,
        .dmabuf_feedback,
        .foreign_parent,
        => .daemon_only,
        // `Tag` is non-exhaustive on the wire; a value this build has no
        // name for is fail-closed: never an intent, never dispatched.
        _ => .daemon_only,
    };
}

/// Viewer→daemon bytes on a native channel: seat intents drive
/// the brain; clipboard units keep their legacy handling. Raw
/// wl_msg from viewers is IGNORED — the daemon brain is the only
/// protocol driver (a replica answering too would double-drive
/// the app).
pub fn nativeClientData(self: *Daemon, cl: *Client, ch: *Channel, bytes: []const u8) void {
    const nv = ch.native.?;
    const drives = isController(cl, ch.session.?);
    nv.unitbuf.appendSlice(nv.allocator, bytes) catch {
        self.closeChannel(ch, true);
        return;
    };
    var pos: usize = 0;
    while (!ch.dead) {
        const peeled = wlpipe.peelUnit(nv.unitbuf.items[pos..]) catch {
            self.closeChannel(ch, true);
            return;
        } orelse break;
        switch (viewerUnitKind(peeled.unit.tag)) {
            // Non-controller input is DROPPED (not queued): a
            // stale pointer/key stream replayed later would be
            // worse than never having been sent.
            .intent => if (drives) nv.brain.applyIntent(peeled.unit.tag, peeled.unit.payload),
            .describe => nv.brain.applyIntent(peeled.unit.tag, peeled.unit.payload),
            .transfer => applyAppUnit(self, ch, peeled.unit.tag, peeled.unit.payload),
            .daemon_only => {},
        }
        pos += peeled.consumed;
    }
    if (pos > 0) {
        const rem = nv.unitbuf.items.len - pos;
        std.mem.copyForwards(u8, nv.unitbuf.items[0..rem], nv.unitbuf.items[pos..]);
        nv.unitbuf.shrinkRetainingCapacity(rem);
    }
    if (!ch.dead) flushBrain(self, ch);
    if (!ch.dead) self.channelWritable(ch);
}

/// Take the held paste-fd for `offer` (falls back to the oldest
/// entry — pre-tagging senders). Caller owns the fd.
pub fn takePasteFd(nv: *Native, offer: u32) ?c_int {
    for (nv.clip_paste_fds.items, 0..) |p, i| {
        if (p.offer == offer) return nv.clip_paste_fds.orderedRemove(i).fd;
    }
    if (nv.clip_paste_fds.items.len == 0) return null;
    return nv.clip_paste_fds.orderedRemove(0).fd;
}

/// Apply one unit TOWARD the app socket: brain output (wl_msg
/// events, keymap side-band) and viewer clipboard units.
pub fn applyAppUnit(self: *Daemon, ch: *Channel, tag: wlpipe.Tag, payload: []const u8) void {
    const nv = ch.native.?;
    switch (tag) {
        .wl_msg => {
            // One Wayland message per unit (pipe contract).
            const maybe_hdr = wlwire.parseHeader(payload) catch null;
            if (maybe_hdr) |h| {
                nv.tracker.serverMessage(h, payload[wlwire.header_size..]) catch {};
            }
            ch.pending.appendSlice(ch.allocator, payload) catch {
                self.closeChannel(ch, true);
                return;
            };
        },
        .keymap => {
            // u32 keyboard id, u32 format, keymap bytes.
            // Materialize an anon fd and emit the real
            // wl_keyboard.keymap(format, fd, size) event.
            const pl = payload;
            if (pl.len < 8) return;
            const kbd = std.mem.readInt(u32, pl[0..4], .little);
            const format = std.mem.readInt(u32, pl[4..8], .little);
            const blob = pl[8..];
            // NUL-terminated per xkb convention.
            const fd = @import("../util/platform.zig").anonFileFd(blob.len + 1);
            if (fd < 0) return;
            var written: usize = 0;
            var w_ok = true;
            while (written < blob.len) {
                const w = c.write(fd, blob.ptr + written, blob.len - written);
                if (w <= 0) {
                    w_ok = false;
                    break;
                }
                written += @intCast(w);
            }
            if (!w_ok) {
                _ = c.close(fd);
                return;
            }
            var mbuf: [24]u8 = undefined;
            var b = wlwire.Builder.init(&mbuf, kbd, 0); // keymap
            b.putUint(format);
            // 'h' fd arg: no bytes on the wire
            b.putUint(@intCast(blob.len + 1));
            const msg = b.finish() catch {
                _ = c.close(fd);
                return;
            };
            ch.pending.appendSlice(ch.allocator, msg) catch {
                _ = c.close(fd);
                self.closeChannel(ch, true);
                return;
            };
            nv.out_fds.append(nv.allocator, fd) catch {
                _ = c.close(fd);
            };
        },
        .dmabuf_feedback => {
            // u32 feedback object id, then the format table.
            // Materialize an anon fd and emit the real
            // zwp_linux_dmabuf_feedback_v1.format_table(fd, size).
            const pl = payload;
            if (pl.len < 4) return;
            const obj = std.mem.readInt(u32, pl[0..4], .little);
            const table = pl[4..];
            const fd = @import("../util/platform.zig").anonFileFd(table.len);
            if (fd < 0) return;
            var written: usize = 0;
            while (written < table.len) {
                const w = c.write(fd, table.ptr + written, table.len - written);
                if (w <= 0) {
                    _ = c.close(fd);
                    return;
                }
                written += @intCast(w);
            }
            var mbuf: [16]u8 = undefined;
            var b = wlwire.Builder.init(&mbuf, obj, 1); // format_table
            // 'h' fd arg: no bytes on the wire
            b.putUint(@intCast(table.len));
            const msg = b.finish() catch {
                _ = c.close(fd);
                return;
            };
            ch.pending.appendSlice(ch.allocator, msg) catch {
                _ = c.close(fd);
                self.closeChannel(ch, true);
                return;
            };
            nv.out_fds.append(nv.allocator, fd) catch {
                _ = c.close(fd);
            };
        },
        .clip_send => {
            // GUI fetches the app's clipboard: pipe(), the
            // write-end rides a wl_data_source.send event,
            // the read-end is polled until the app's EOF.
            const pl = payload;
            if (pl.len < 4) return;
            const source = std.mem.readInt(u32, pl[0..4], .little);
            const mime = pl[4..];

            // `send` is opcode 1 on wl_data_source but opcode 0
            // on the zwlr-data-control and primary-selection
            // sources — pick by the tracked interface.
            const send_op: u16 = if (nv.tracker.objects.get(source)) |sif|
                (if (sif == &wlproto.zwlr_data_control_source_v1 or
                    sif == &wlproto.zwp_primary_selection_source_v1) 0 else 1)
            else
                1;
            // Build the message before pipe() so every early exit
            // from here on either precedes the fds or closes them.
            const msg_cap = wlwire.header_size + 4 + ((mime.len + 1 + 3) & ~@as(usize, 3));
            if (msg_cap > 0xffff) return;
            const mbuf = ch.allocator.alloc(u8, msg_cap) catch return;
            defer ch.allocator.free(mbuf);
            var b = wlwire.Builder.init(mbuf, source, send_op); // send
            b.putString(mime);
            const msg = b.finish() catch return;

            var pfds: [2]c_int = undefined;
            if (c.pipe(&pfds) != 0) return;
            _ = c.fcntl(pfds[0], c.F_SETFD, c.FD_CLOEXEC);
            _ = c.fcntl(pfds[1], c.F_SETFD, c.FD_CLOEXEC);
            const fl = c.fcntl(pfds[0], c.F_GETFL, @as(c_int, 0));
            _ = c.fcntl(pfds[0], c.F_SETFL, fl | c.O_NONBLOCK);
            ch.pending.appendSlice(ch.allocator, msg) catch {
                _ = c.close(pfds[0]);
                _ = c.close(pfds[1]);
                self.closeChannel(ch, true);
                return;
            };
            nv.out_fds.append(nv.allocator, pfds[1]) catch {
                _ = c.close(pfds[1]);
            };
            nv.clip_reads.append(nv.allocator, .{ .fd = pfds[0] }) catch {
                _ = c.close(pfds[0]);
            };
        },
        .clip_data => {
            // Paste bytes for the oldest held receive-fd.
            if (nv.clip_paste_fds.items.len == 0) return;
            const fd = nv.clip_paste_fds.orderedRemove(0).fd;
            var written: usize = 0;
            while (written < payload.len) {
                const w = c.write(fd, payload.ptr + written, payload.len - written);
                if (w <= 0) break;
                written += @intCast(w);
            }
            _ = c.close(fd);
        },
        .drop_data => {
            // Host-drop transfer: write the payload into the
            // fd held FOR THAT OFFER.
            const pl = payload;
            if (pl.len < 4) return;
            const offer = std.mem.readInt(u32, pl[0..4], .little);
            const data = pl[4..];
            const fd = takePasteFd(nv, offer) orelse return;
            var written: usize = 0;
            while (written < data.len) {
                const w = c.write(fd, data.ptr + written, data.len - written);
                if (w <= 0) break;
                written += @intCast(w);
            }
            _ = c.close(fd);
        },
        .primary_data => {
            // Primary-paste bytes for the oldest PRIMARY fd.
            if (nv.primary_paste_fds.items.len == 0) return;
            const fd = nv.primary_paste_fds.orderedRemove(0);
            var written: usize = 0;
            while (written < payload.len) {
                const w = c.write(fd, payload.ptr + written, payload.len - written);
                if (w <= 0) break;
                written += @intCast(w);
            }
            _ = c.close(fd);
        },
        .dnd_send => {
            // Within-app dnd transfer: the drop target's
            // receive-fd (held, keyed by offer) becomes the
            // SOURCE's send fd — data never leaves the host.
            const pl = payload;
            if (pl.len < 8) return;
            const source = std.mem.readInt(u32, pl[0..4], .little);
            const offer = std.mem.readInt(u32, pl[4..8], .little);
            const mime = pl[8..];
            const fd = takePasteFd(nv, offer) orelse return;
            const msg_cap = wlwire.header_size + 4 + ((mime.len + 1 + 3) & ~@as(usize, 3));
            if (msg_cap > 0xffff) {
                _ = c.close(fd);
                return;
            }
            const mbuf = ch.allocator.alloc(u8, msg_cap) catch {
                _ = c.close(fd);
                return;
            };
            defer ch.allocator.free(mbuf);
            var b = wlwire.Builder.init(mbuf, source, 1); // wl_data_source.send
            b.putString(mime);
            const msg = b.finish() catch {
                _ = c.close(fd);
                return;
            };
            ch.pending.appendSlice(ch.allocator, msg) catch {
                _ = c.close(fd);
                self.closeChannel(ch, true);
                return;
            };
            nv.out_fds.append(nv.allocator, fd) catch {
                _ = c.close(fd);
            };
        },
        // Unknown tags skip for forward compat.
        else => {},
    }
}

// --- tests ------------------------------------------------------

test "every viewer unit tag is classified, and the gate reads the classification" {
    const t = std.testing;
    // The switch in viewerUnitKind is exhaustive (a new tag fails to
    // compile), so what this pins is the MEMBERSHIP: which tags drive
    // the app, which answer or describe, and that nothing else is
    // accepted from a viewer.
    const intents = [_]wlpipe.Tag{
        .seat_enter,    .seat_leave,     .seat_motion,    .seat_button,
        .seat_axis,     .seat_kbd_enter, .seat_kbd_leave, .seat_key,
        .seat_mods,     .configure,      .dismiss_popups, .text_commit,
        .request_close, .host_drop,
    };
    const describes = [_]wlpipe.Tag{ .offer_selection, .offer_primary, .set_scale };
    const transfers = [_]wlpipe.Tag{ .clip_send, .clip_data, .primary_data };
    inline for (@typeInfo(wlpipe.Tag).@"enum".fields) |f| {
        const tag: wlpipe.Tag = @enumFromInt(f.value);
        const kind = viewerUnitKind(tag);
        const expected: ViewerUnit = if (std.mem.indexOfScalar(wlpipe.Tag, &intents, tag) != null)
            .intent
        else if (std.mem.indexOfScalar(wlpipe.Tag, &describes, tag) != null)
            .describe
        else if (std.mem.indexOfScalar(wlpipe.Tag, &transfers, tag) != null)
            .transfer
        else
            .daemon_only;
        try t.expectEqual(expected, kind);
        try t.expectEqual(kind == .intent, isSeatIntent(tag));
    }
}

test "a shm fd is refused for a pool larger than its backing file" {
    const t = std.testing;
    const fd = @import("../util/platform.zig").anonFileFd(4096);
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    try t.expect(fdBacksBytes(fd, 4096));
    try t.expect(!fdBacksBytes(fd, 4097));
    try t.expect(!fdBacksBytes(-1, 1)); // unstattable fails closed
}

test "the fd pairing contract accepts exact consumption only" {
    const t = std.testing;
    try t.expect(fdPairingHolds(0, 3, 3));
    try t.expect(fdPairingHolds(1, 3, 2));
    try t.expect(fdPairingHolds(4, 4, 0));
    try t.expect(!fdPairingHolds(1, 3, 3)); // an arm forgot its pop: a leak
    try t.expect(!fdPairingHolds(0, 3, 2)); // an arm popped without a declaration
    try t.expect(!fdPairingHolds(2, 1, 0)); // consumed more than was held
    // libwayland flushes its out queue at 28 pending descriptors, so
    // that many can legitimately precede their message; the ceiling
    // must sit above it or a well-behaved client is killed.
    try t.expect(MAX_PENDING_FDS > 28);
}

test "declared descriptor counts come from the bound interface's signature" {
    const t = std.testing;
    var tracker = try wltrack.Tracker.init(t.allocator);
    defer tracker.deinit();
    try tracker.objects.put(t.allocator, 5, &wlproto.wl_shm);
    const nv: Native = .{ .allocator = t.allocator, .tracker = tracker, .brain = undefined };
    try t.expectEqual(@as(u32, 1), requestFdCount(&nv, .{ .object = 5, .opcode = 0, .size = 8 })); // create_pool "nhi"
    try t.expectEqual(@as(u32, 0), requestFdCount(&nv, .{ .object = 5, .opcode = 1, .size = 8 })); // release ""
    try t.expectEqual(@as(u32, 0), requestFdCount(&nv, .{ .object = 5, .opcode = 9, .size = 8 })); // unknown opcode
    try t.expectEqual(@as(u32, 0), requestFdCount(&nv, .{ .object = 6, .opcode = 0, .size = 8 })); // unknown object
}

/// A Native wired to a session-less Channel, enough for nativeAction's
/// shm arms: refusals land in `ch.pending`, and hasNativeViewer answers
/// true without consulting a Daemon.
const ActionRig = struct {
    daemon: Daemon,
    /// Heap-allocated because Native.deinit destroys itself.
    nv: *Native,
    ch: Channel,
    units: std.ArrayList(u8) = .empty,

    fn init(rig: *ActionRig, a: std.mem.Allocator) !void {
        rig.daemon = undefined;
        rig.daemon.allocator = a;
        const brain = try a.create(wlcomp.Compositor);
        errdefer a.destroy(brain);
        brain.* = try wlcomp.Compositor.init(a, .{});
        errdefer brain.deinit();
        const nv = try a.create(Native);
        errdefer a.destroy(nv);
        nv.* = .{ .allocator = a, .tracker = try wltrack.Tracker.init(a), .brain = brain };
        rig.nv = nv;
        rig.ch = .{ .allocator = a, .id = 1, .fd = -1, .session = null, .client = null };
        rig.nv.chan = &rig.ch;
        rig.units = .empty;
    }

    fn deinit(rig: *ActionRig) void {
        const a = rig.nv.allocator;
        rig.nv.deinit();
        rig.ch.pending.deinit(a);
        rig.units.deinit(a);
    }

    fn act(rig: *ActionRig, action: wltrack.Action) !void {
        return nativeAction(&rig.daemon, rig.nv, &rig.units, "", action);
    }
};

test "pool_create past the backing file is a readable protocol error and closes the fd" {
    const t = std.testing;
    var rig: ActionRig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const fd = @import("../util/platform.zig").anonFileFd(4096);
    try t.expect(fd >= 0);
    try rig.nv.fds.append(t.allocator, fd);
    try t.expectError(error.CloseAfterFlush, rig.act(.{ .pool_create = .{ .id = 3, .size = 8192, .serial = 1 } }));
    try t.expect(rig.ch.close_after_flush);
    try t.expect(rig.ch.pending.items.len > 0); // the wl_display.error frame
    try t.expectEqual(@as(usize, 0), rig.nv.pools.count());
    try t.expectEqual(@as(usize, 0), rig.units.items.len); // no replica heard of it
    try t.expect(c.fcntl(fd, c.F_GETFD) < 0); // the errdefer closed it
}

test "pool_resize past the backing file is refused and the mirror keeps its last good size" {
    const t = std.testing;
    var rig: ActionRig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const fd = @import("../util/platform.zig").anonFileFd(4096);
    try t.expect(fd >= 0);
    try rig.nv.fds.append(t.allocator, fd);
    try rig.act(.{ .pool_create = .{ .id = 3, .size = 4096, .serial = 1 } });
    try t.expectEqual(@as(usize, 4096), rig.nv.pools.get(3).?.size);
    try t.expectError(error.CloseAfterFlush, rig.act(.{ .pool_resize = .{ .id = 3, .size = 8192 } }));
    try t.expect(rig.ch.close_after_flush);
    try t.expectEqual(@as(usize, 4096), rig.nv.pools.get(3).?.size);
    // The honest sequence: grow the object first, then resize.
    rig.ch.close_after_flush = false;
    try t.expect(c.ftruncate(fd, 8192) == 0);
    try rig.act(.{ .pool_resize = .{ .id = 3, .size = 8192 } });
    try t.expectEqual(@as(usize, 8192), rig.nv.pools.get(3).?.size);
}

test "a committed buffer's rows are copied out of the client fd, and a pool shrunk under it is a protocol error, not a fault" {
    const t = std.testing;
    var rig: ActionRig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const fd = @import("../util/platform.zig").anonFileFd(4096);
    try t.expect(fd >= 0);
    var fill: [4096]u8 = undefined;
    @memset(&fill, 0xAB);
    try t.expectEqual(@as(isize, 4096), c.pwrite(fd, &fill, fill.len, 0));
    try rig.nv.fds.append(t.allocator, fd);
    try rig.act(.{ .pool_create = .{ .id = 3, .size = 4096, .serial = 1 } });
    const info: wltrack.BufferInfo = .{ .pool = 3, .offset = 0, .width = 16, .height = 16, .stride = 64, .format = 0, .serial = 1 };
    try rig.nv.tracker.buffers.put(t.allocator, 7, info);
    const commit: wltrack.Action = .{ .commit = .{ .surface = 9, .buffer = 7, .info = info, .damage = .{ .y0 = 2, .y1 = 3 }, .attached_now = true } };
    try rig.act(commit);
    // First commit pulls the WHOLE buffer despite the one-row damage.
    const mirror = rig.nv.pools.get(3).?;
    try t.expect(std.mem.allEqual(u8, mirror.ptr[0..1024], 0xAB));
    try t.expect(rig.nv.tracker.buffers.get(7).?.pulled);
    // A later commit copies only the damaged rows.
    @memset(&fill, 0xCD);
    try t.expectEqual(@as(isize, 4096), c.pwrite(fd, &fill, fill.len, 0));
    try rig.act(commit);
    try t.expect(std.mem.allEqual(u8, mirror.ptr[128..192], 0xCD)); // row 2
    try t.expect(std.mem.allEqual(u8, mirror.ptr[0..128], 0xAB)); // rows 0-1 untouched
    // The client shrinks the object under its own buffer: the daemon
    // used to SIGBUS reading the mapping; now the app gets wl_shm's
    // invalid_fd and the channel closes after the flush.
    try t.expect(c.ftruncate(fd, 64) == 0);
    try t.expectError(error.CloseAfterFlush, rig.act(commit));
    try t.expect(rig.ch.close_after_flush);
}

test "pullPoolRows reports a shrunk object as PoolShrunk" {
    const t = std.testing;
    const fd = @import("../util/platform.zig").anonFileFd(4096);
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    const mirror = mapMirror(4096) orelse return error.SkipZigTest;
    defer _ = c.munmap(mirror, 4096);
    try pullPoolRows(fd, mirror, 0, 4096);
    try t.expect(c.ftruncate(fd, 1024) == 0);
    try t.expectError(error.PoolShrunk, pullPoolRows(fd, mirror, 0, 4096));
    try t.expectError(error.ReadFailed, pullPoolRows(-1, mirror, 0, 16));
}

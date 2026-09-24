# Video streaming for forwarded apps

A forwarded app window (a Wayland app on a session display, local or
remote) normally reaches the viewer as **lossless** pixel updates
(`pool_update_c`, `wlhost/pixcodec.zig`). That is exact and cheap for
text, UIs and anything mostly static. For a busy, photographic surface
(a video player, a game, a camera feed) it is the worst case: every
frame changes almost every pixel. Those surfaces switch to **lossy
video tiles** (`pool_vtile`) in a codec both ends support.

## When a surface goes video

Per commit, in the session daemon (`daemon.zig Native.videoCommit`):

1. the channel has a negotiated codec (below), otherwise lossless;
2. the surface is HOT (`util/churn.zig`: damaged on most recent frames)
   and its size is even in both dimensions;
3. the frame looks PHOTOGRAPHIC (`util/content.zig`: thousands of
   distinct colours; text and flat UI stay lossless even when hot).

Then the whole surface is encoded as one tile and shipped as a
`pool_vtile` unit that the viewer decodes into the same pool mirror a
lossless update would have written, so both kinds composite
identically. A surface drops back to lossless the moment it cools down
or stops looking photographic. dma-buf and orphan-pool commits always
stay lossless.

Encoder state is per (surface, pool): every receiver keeps one decoder
per pool, so a surface whose buffers live in different pools (mpv's
`wlshm` output uses one pool per buffer) feeds each pool its own
self-consistent stream. A new encoder, a (re)attaching viewer and a
frame the daemon had to skip (viewer backlog) all force a keyframe.
The viewer drops a tile it cannot decode (the mirror keeps the previous
frame; the next keyframe recovers) instead of failing the channel.

## Codecs and where they run

| codec | encode (daemon) | decode (viewer) |
|---|---|---|
| `h264` | libx264, ultrafast/zerolatency, CRF 24, full-range | libavcodec |
| `h264` on a native macOS daemon | VideoToolbox (winstream path) | libavcodec |
| `av1` | SVT-AV1 (libSvtAv1Enc), preset 12, low delay | libavcodec (libdav1d) |

Every library is **runtime-loaded** (`dlopen`, like libopus): `-Dvideo`
compiles the C shims (`vendor/x264_shim.c`, `vendor/svtav1_shim.c`,
`vendor/avdec_shim.c`) against the headers only, and each call goes
through a `dlsym`'d pointer. The soname is built from the header's
major version, so a runtime of a different ABI simply fails to load.
`sketerm-mux` therefore keeps a libc-only ELF graph, and the daemon
never loads libavcodec (it only encodes). What a process can do is a
runtime fact: `sketerm doctor` prints `video decode:... encode:...`
for the binary and the daemon's encode set.

`SKETERM_VIDEO_DISABLE=h264,av1` (or `all`) makes a process behave as if
those libraries were missing, for testing the fallbacks.

## Negotiation

- The viewer's hello carries `video_codecs`: the codecs it can decode,
  in its preference order (config `app_video_codec`: `auto` = H.264
  then AV1; `h264`/`av1` = that one first; `lossless` = none). It also
  sets the old `video` bool to "I decode H.264".
- The daemon keeps that list per client and, per session, picks the
  first codec of the first viewer's list that EVERY native viewer lists
  and this daemon can encode (`vcodec.negotiate`). It re-picks whenever
  a viewer attaches or leaves; a changed codec reopens the encoder.
- The welcome keeps `video` (= the daemon can encode H.264) and adds
  `video_codecs` (its encode set), informational.

Compatibility, both directions (append-only, unit-tested):

- An **old GUI** sends only `video: true`. The daemon reads that as
  `{h264}`, so it gets x264, never AV1 (`daemon_serve.zig` HelloReq test).
- An **old daemon** reads only `video` and encodes x264 when it is set,
  which a new GUI sets exactly when it can decode H.264
  (`client.zig helloVideo` test).
- The broker's worker handoff datagram (`PassedClient`) keeps byte 1 as
  the bool and appends the list; an old 12-byte handoff decodes to
  `{h264}`/none (`daemon_control.zig` test).

## Building and packaging

`-Dvideo` is auto-detected at configure time: on when pkg-config finds
`x264`, `libavcodec` and `libavutil` headers, with AV1 encode also
needing `SvtAv1Enc`. Missing headers print a note and build without
video (apps forward losslessly); `-Dvideo=true` turns missing headers
into an error, `-Dvideo=false` opts out silently. `mux-portable` never
has video. Arch: `x264 svt-av1 ffmpeg` are makedepends and optdepends.
Debian/Ubuntu `--deps`: `libx264-dev libavcodec-dev libavutil-dev
libsvtav1enc-dev` are optional build deps; `ffmpeg` is Recommended.

## Not implemented

- Hardware encode/decode (VAAPI). A render node exists on some hosts,
  but a VAAPI encoder would need libavcodec (and its GLib/X11
  dependency tail) inside the daemon, or a separate helper process;
  neither is wired.
- Partial-surface (tile-grid) encode: a hot surface is always encoded
  whole; inter-frame prediction keeps unchanged areas cheap.

## Testing

- Unit: `wlhost/vcodec.zig` (x264 and SVT-AV1 round trips through
  libavcodec, `Encoder.init` per codec, negotiation and list tests),
  plus the compatibility tests above.
- `zig build smoke-video`: a real mpv (`--vo=wlshm`) plays a noisy test
  pattern on a session display; per stage a replica-compositor viewer
  (the GUI's decode path) negotiates lossless (the reference), the
  legacy bool, `h264` and `av1`, and must receive tiles in exactly that
  codec, starting with a keyframe, with no decode errors, and decoding
  to the reference colours. It skips without `-Dvideo` or mpv
  (`SKETERM_SMOKE_VIDEO_REQUIRE=1` makes that a failure).

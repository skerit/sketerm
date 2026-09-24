// Minimal C shim over libavcodec for video-tile decode — the receive-side
// counterpart of x264_shim.c / svtav1_shim.c. Decodes one access unit
// (H.264 Annex-B, or an AV1 temporal unit through whatever AV1 decoder
// libavcodec prefers — libdav1d on every mainstream build) to a planar
// I420 frame and copies the planes out tightly; the Zig side
// (src/wlhost/vcodec.zig AvDec) turns I420→BGRA via yuv.zig.
//
// libavcodec/libavutil are RUNTIME-LOADED like libx264: compiled against
// the headers only (build.zig addVideo), bound through `sk_av_bind` from
// handles vcodec.zig dlopen'd by the header's major versions, so no
// binary gains an ELF dependency and a host without ffmpeg just does not
// advertise the codecs. Software decode; hardware decode is not wired.

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>

static struct {
    int bound;
    const AVCodec *(*find_decoder)(enum AVCodecID);
    AVCodecContext *(*alloc_context3)(const AVCodec *);
    int (*open2)(AVCodecContext *, const AVCodec *, AVDictionary **);
    int (*send_packet)(AVCodecContext *, const AVPacket *);
    int (*receive_frame)(AVCodecContext *, AVFrame *);
    void (*free_context)(AVCodecContext **);
    AVPacket *(*packet_alloc)(void);
    void (*packet_free)(AVPacket **);
    AVFrame *(*frame_alloc)(void);
    void (*frame_free)(AVFrame **);
    void (*log_set_level)(int);
} A;

// Header major versions: the Zig loader dlopens exactly these sonames
// (`libavcodec.so.<n>`, `libavutil.so.<n>`), the ABI the struct offsets
// used below were compiled for.
int sk_av_codec_major(void) { return LIBAVCODEC_VERSION_MAJOR; }
int sk_av_util_major(void) { return LIBAVUTIL_VERSION_MAJOR; }

// Resolve every entry point. 1 = usable, 0 = not. Idempotent.
int sk_av_bind(void *hcodec, void *hutil) {
    if (A.bound) return 1;
    if (!hcodec || !hutil) return 0;
    A.find_decoder = dlsym(hcodec, "avcodec_find_decoder");
    A.alloc_context3 = dlsym(hcodec, "avcodec_alloc_context3");
    A.open2 = dlsym(hcodec, "avcodec_open2");
    A.send_packet = dlsym(hcodec, "avcodec_send_packet");
    A.receive_frame = dlsym(hcodec, "avcodec_receive_frame");
    A.free_context = dlsym(hcodec, "avcodec_free_context");
    A.packet_alloc = dlsym(hcodec, "av_packet_alloc");
    A.packet_free = dlsym(hcodec, "av_packet_free");
    A.frame_alloc = dlsym(hutil, "av_frame_alloc");
    A.frame_free = dlsym(hutil, "av_frame_free");
    A.log_set_level = dlsym(hutil, "av_log_set_level");
    if (!A.find_decoder || !A.alloc_context3 || !A.open2 || !A.send_packet || !A.receive_frame ||
        !A.free_context || !A.packet_alloc || !A.packet_free || !A.frame_alloc || !A.frame_free ||
        !A.log_set_level)
        return 0;
    // A corrupt tile is handled (dropped) by the caller; libav's own
    // complaints would only spam the GUI's stderr.
    A.log_set_level(AV_LOG_QUIET);
    A.bound = 1;
    return 1;
}

static enum AVCodecID codec_id(int which) {
    return (which == 1) ? AV_CODEC_ID_AV1 : AV_CODEC_ID_H264;
}

// 1 when the bound libavcodec has a decoder for `which` (0 = H.264,
// 1 = AV1). An AV1-less ffmpeg build (no libdav1d, no native decoder)
// must not advertise AV1.
int sk_avdec_has(int which) {
    if (!A.bound) return 0;
    return A.find_decoder(codec_id(which)) != NULL;
}

typedef struct {
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frm;
} sk_avdec;

void sk_avdec_close(void *dec);

// `which`: 0 = H.264, 1 = AV1.
void *sk_avdec_open(int which) {
    if (!A.bound) return NULL;
    const AVCodec *codec = A.find_decoder(codec_id(which));
    if (!codec) return NULL;
    sk_avdec *d = (sk_avdec *)calloc(1, sizeof(sk_avdec));
    if (!d) return NULL;
    d->ctx = A.alloc_context3(codec);
    d->pkt = A.packet_alloc();
    d->frm = A.frame_alloc();
    if (!d->ctx || !d->pkt || !d->frm) { sk_avdec_close(d); return NULL; }
    // Low-latency: frame-threading buffers thread_count frames before
    // emitting the first, which would stall a tile stream. One thread +
    // LOW_DELAY makes each (B-frame-free) packet decode to a frame now.
    d->ctx->thread_count = 1;
    d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    if (A.open2(d->ctx, codec, NULL) < 0) { sk_avdec_close(d); return NULL; }
    return d;
}

// Decode one access unit. On a decoded frame matching exp_w×exp_h
// I420, copies tight Y/U/V planes into the caller's buffers (sized w*h
// and (w/2)*(h/2)) and returns 1. Returns 0 if no frame is ready yet,
// < 0 on error or an unexpected format/size.
int sk_avdec_decode(void *dec, const uint8_t *data, int len, int exp_w, int exp_h,
                    uint8_t *y, uint8_t *u, uint8_t *v) {
    sk_avdec *d = (sk_avdec *)dec;
    d->pkt->data = (uint8_t *)data;
    d->pkt->size = len;
    if (A.send_packet(d->ctx, d->pkt) < 0) return -1;
    int r = A.receive_frame(d->ctx, d->frm);
    if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
    if (r < 0) return -1;
    // Accept both: a full-range stream (x264 b_fullrange, SVT-AV1
    // color-range=1) decodes as the J variant or as YUV420P with
    // color_range JPEG; same I420 plane layout, and yuv.zig already
    // does full-range conversion.
    if (d->frm->format != AV_PIX_FMT_YUV420P && d->frm->format != AV_PIX_FMT_YUVJ420P) return -2;
    int w = d->frm->width, h = d->frm->height;
    if (w != exp_w || h != exp_h) return -3;
    int cw = w / 2, ch = h / 2;
    for (int row = 0; row < h; row++)
        memcpy(y + (size_t)row * w, d->frm->data[0] + (size_t)row * d->frm->linesize[0], (size_t)w);
    for (int row = 0; row < ch; row++) {
        memcpy(u + (size_t)row * cw, d->frm->data[1] + (size_t)row * d->frm->linesize[1], (size_t)cw);
        memcpy(v + (size_t)row * cw, d->frm->data[2] + (size_t)row * d->frm->linesize[2], (size_t)cw);
    }
    return 1;
}

void sk_avdec_close(void *dec) {
    sk_avdec *d = (sk_avdec *)dec;
    if (!d) return;
    if (d->frm) A.frame_free(&d->frm);
    if (d->pkt) A.packet_free(&d->pkt);
    if (d->ctx) A.free_context(&d->ctx);
    free(d);
}

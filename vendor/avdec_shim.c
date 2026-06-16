// Minimal C shim over libavcodec for H.264 decode — the receive-side
// counterpart of x264_shim.c. Decodes one Annex-B access unit to a
// planar I420 frame and copies the planes out tightly; the Zig side
// (src/wlhost/vcodec.zig avcodec Decoder) turns I420→BGRA via yuv.zig.
// Software decode here; VAAPI hwaccel is a later optimization on top.
// Compiled + linked only on GUI builds with -Dvideo (build.zig addVideo).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>

typedef struct {
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frm;
} sk_avdec;

void sk_avdec_close(void *dec);

// `which`: 0 = H.264, 1 = AV1.
void *sk_avdec_open(int which) {
    enum AVCodecID id = (which == 1) ? AV_CODEC_ID_AV1 : AV_CODEC_ID_H264;
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec) return NULL;
    sk_avdec *d = (sk_avdec *)calloc(1, sizeof(sk_avdec));
    if (!d) return NULL;
    d->ctx = avcodec_alloc_context3(codec);
    d->pkt = av_packet_alloc();
    d->frm = av_frame_alloc();
    if (!d->ctx || !d->pkt || !d->frm) { sk_avdec_close(d); return NULL; }
    // Low-latency: frame-threading buffers thread_count frames before
    // emitting the first, which would stall a tile stream. One thread +
    // LOW_DELAY makes each (B-frame-free) packet decode to a frame now.
    d->ctx->thread_count = 1;
    d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    if (avcodec_open2(d->ctx, codec, NULL) < 0) { sk_avdec_close(d); return NULL; }
    return d;
}

// Decode one Annex-B access unit. On a decoded frame matching exp_w×exp_h
// I420, copies tight Y/U/V planes into the caller's buffers (sized w*h
// and (w/2)*(h/2)) and returns 1. Returns 0 if no frame is ready yet,
// < 0 on error or an unexpected format/size.
int sk_avdec_decode(void *dec, const uint8_t *data, int len, int exp_w, int exp_h,
                    uint8_t *y, uint8_t *u, uint8_t *v) {
    sk_avdec *d = (sk_avdec *)dec;
    d->pkt->data = (uint8_t *)data;
    d->pkt->size = len;
    if (avcodec_send_packet(d->ctx, d->pkt) < 0) return -1;
    int r = avcodec_receive_frame(d->ctx, d->frm);
    if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
    if (r < 0) return -1;
    // Accept both: a full-range stream (we set x264 b_fullrange) decodes
    // as the J variant; same I420 plane layout, and yuv.zig already does
    // full-range conversion.
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
    if (d->frm) av_frame_free(&d->frm);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->ctx) avcodec_free_context(&d->ctx);
    free(d);
}

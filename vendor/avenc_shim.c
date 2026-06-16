// Generic libavcodec encoder shim — used for AV1 (libsvtav1); H.264 uses
// direct libx264 (x264_shim.c) for lowest latency. Same shim discipline:
// the Zig side (src/wlhost/vcodec.zig) calls it via extern fn. Encodes
// full-range I420 with a low-delay configuration so each input frame
// emits a packet immediately (no lookahead/B-frame buffering).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>

typedef struct {
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frm;
    int64_t pts;
} sk_avenc;

void sk_avenc_close(void *enc);

// Open `codec_name` (e.g. "libsvtav1") for width×height I420 at `fps`.
void *sk_avenc_open(const char *codec_name, int width, int height, int fps) {
    const AVCodec *codec = avcodec_find_encoder_by_name(codec_name);
    if (!codec) return NULL;
    sk_avenc *e = (sk_avenc *)calloc(1, sizeof(sk_avenc));
    if (!e) return NULL;
    e->ctx = avcodec_alloc_context3(codec);
    e->pkt = av_packet_alloc();
    e->frm = av_frame_alloc();
    if (!e->ctx || !e->pkt || !e->frm) { sk_avenc_close(e); return NULL; }

    e->ctx->width = width;
    e->ctx->height = height;
    e->ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    e->ctx->time_base = (AVRational){ 1, (fps > 0) ? fps : 30 };
    e->ctx->framerate = (AVRational){ (fps > 0) ? fps : 30, 1 };
    e->ctx->gop_size = 120;
    e->ctx->max_b_frames = 0;
    e->ctx->thread_count = 1;
    e->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    // SVT-AV1: fastest preset + low-delay prediction, no lookahead — so a
    // frame in produces a packet out immediately (real-time tile stream).
    av_opt_set(e->ctx->priv_data, "preset", "12", 0);
    av_opt_set(e->ctx->priv_data, "svtav1-params", "pred-struct=1:lookahead=0:enable-tpl-la=0", 0);

    if (avcodec_open2(e->ctx, codec, NULL) < 0) { sk_avenc_close(e); return NULL; }
    e->frm->format = AV_PIX_FMT_YUV420P;
    e->frm->width = width;
    e->frm->height = height;
    if (av_frame_get_buffer(e->frm, 0) < 0) { sk_avenc_close(e); return NULL; }
    return e;
}

// Encode one tight I420 frame. On a packet, returns its size, sets *out
// (valid until the next encode call) and *is_kf. 0 = buffered (no output
// this call), < 0 on error.
int sk_avenc_encode(void *enc, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                    int force_kf, const uint8_t **out, int *is_kf) {
    sk_avenc *e = (sk_avenc *)enc;
    av_packet_unref(e->pkt); // release the previous frame's packet
    if (av_frame_make_writable(e->frm) < 0) return -1;

    const int w = e->ctx->width, h = e->ctx->height, cw = w / 2, ch = h / 2;
    for (int r = 0; r < h; r++)
        memcpy(e->frm->data[0] + (size_t)r * e->frm->linesize[0], y + (size_t)r * w, (size_t)w);
    for (int r = 0; r < ch; r++) {
        memcpy(e->frm->data[1] + (size_t)r * e->frm->linesize[1], u + (size_t)r * cw, (size_t)cw);
        memcpy(e->frm->data[2] + (size_t)r * e->frm->linesize[2], v + (size_t)r * cw, (size_t)cw);
    }
    e->frm->pts = e->pts++;
    e->frm->pict_type = force_kf ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

    if (avcodec_send_frame(e->ctx, e->frm) < 0) return -1;
    int r = avcodec_receive_packet(e->ctx, e->pkt);
    if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
    if (r < 0) return -1;
    *out = e->pkt->data;
    *is_kf = (e->pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
    return e->pkt->size;
}

void sk_avenc_close(void *enc) {
    sk_avenc *e = (sk_avenc *)enc;
    if (!e) return;
    if (e->frm) av_frame_free(&e->frm);
    if (e->pkt) av_packet_free(&e->pkt);
    if (e->ctx) avcodec_free_context(&e->ctx);
    free(e);
}

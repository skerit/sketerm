// libvpx VP9 encoder shim — wraps the vpx_codec encode API behind a
// tiny extern surface (the Zig side, src/util/videorec.zig, calls it
// via extern fn). Same discipline as x264_shim.c: keep libvpx's
// config structs out of translate-c. Real-time, no frame lag, so one
// input I420 frame yields at most one compressed CX_FRAME packet.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define VPX_CODEC_DISABLE_COMPAT 1
#include <vpx/vpx_encoder.h>
#include <vpx/vp8cx.h>

typedef struct {
    vpx_codec_ctx_t ctx;
    vpx_image_t img;
    int w, h;
    long frame_index;
    // Last emitted packet, owned here until the next encode/flush.
    uint8_t *pkt;
    size_t pkt_cap;
} sk_vpxenc;

// Open a VP9 encoder for w x h at `fps` frames/sec targeting
// `bitrate_kbps`. Returns NULL on failure.
void *sk_vpxenc_open(int w, int h, int fps, int bitrate_kbps) {
    if (w <= 0 || h <= 0) return NULL;
    // VP9 needs even dimensions for I420 chroma.
    w &= ~1;
    h &= ~1;
    if (w == 0 || h == 0) return NULL;

    sk_vpxenc *e = (sk_vpxenc *)calloc(1, sizeof(sk_vpxenc));
    if (!e) return NULL;
    e->w = w;
    e->h = h;

    vpx_codec_enc_cfg_t cfg;
    if (vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg, 0)) {
        free(e);
        return NULL;
    }
    cfg.g_w = (unsigned int)w;
    cfg.g_h = (unsigned int)h;
    cfg.g_timebase.num = 1;
    cfg.g_timebase.den = fps > 0 ? fps : 30;
    cfg.rc_target_bitrate = bitrate_kbps > 0 ? (unsigned int)bitrate_kbps : 2000;
    cfg.g_error_resilient = 0;
    cfg.g_lag_in_frames = 0;      // no look-ahead: one frame in, one out
    cfg.rc_end_usage = VPX_VBR;
    cfg.g_threads = 4;
    cfg.kf_mode = VPX_KF_AUTO;
    cfg.kf_max_dist = 120;

    if (vpx_codec_enc_init(&e->ctx, vpx_codec_vp9_cx(), &cfg, 0)) {
        free(e);
        return NULL;
    }
    // Real-time speed (cpu-used 6..8 for VP9 realtime).
    vpx_codec_control(&e->ctx, VP8E_SET_CPUUSED, 7);

    if (!vpx_img_alloc(&e->img, VPX_IMG_FMT_I420, (unsigned int)w, (unsigned int)h, 1)) {
        vpx_codec_destroy(&e->ctx);
        free(e);
        return NULL;
    }
    return e;
}

// Copy a tightly-packed I420 buffer (y plane w*h, then u,v each
// (w/2)*(h/2)) into the encoder image, honoring plane strides.
static void fill_img(sk_vpxenc *e, const uint8_t *i420) {
    const int w = e->w, h = e->h;
    const uint8_t *y = i420;
    const uint8_t *u = y + (size_t)w * h;
    const uint8_t *v = u + (size_t)(w / 2) * (h / 2);
    for (int r = 0; r < h; r++)
        memcpy(e->img.planes[VPX_PLANE_Y] + r * e->img.stride[VPX_PLANE_Y], y + (size_t)r * w, w);
    for (int r = 0; r < h / 2; r++) {
        memcpy(e->img.planes[VPX_PLANE_U] + r * e->img.stride[VPX_PLANE_U], u + (size_t)r * (w / 2), w / 2);
        memcpy(e->img.planes[VPX_PLANE_V] + r * e->img.stride[VPX_PLANE_V], v + (size_t)r * (w / 2), w / 2);
    }
}

// Drain one CX_FRAME packet after an encode/flush call. Returns 1 with
// out/out_size/is_kf set when a packet is available, 0 otherwise.
static int drain(sk_vpxenc *e, vpx_codec_iter_t *iter, const uint8_t **out,
                 size_t *out_size, int *is_kf) {
    const vpx_codec_cx_pkt_t *pkt;
    while ((pkt = vpx_codec_get_cx_data(&e->ctx, iter)) != NULL) {
        if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
        size_t sz = pkt->data.frame.sz;
        if (sz > e->pkt_cap) {
            uint8_t *np = (uint8_t *)realloc(e->pkt, sz);
            if (!np) return 0;
            e->pkt = np;
            e->pkt_cap = sz;
        }
        memcpy(e->pkt, pkt->data.frame.buf, sz);
        *out = e->pkt;
        *out_size = sz;
        *is_kf = (pkt->data.frame.flags & VPX_FRAME_IS_KEY) ? 1 : 0;
        return 1;
    }
    return 0;
}

// Encode one I420 frame. On success returns 1 and sets out/out_size/
// is_kf to the compressed packet (owned by the encoder, valid until the
// next call). Returns 0 when no packet was produced, -1 on error.
int sk_vpxenc_encode(void *enc, const uint8_t *i420, int force_kf,
                     const uint8_t **out, size_t *out_size, int *is_kf) {
    sk_vpxenc *e = (sk_vpxenc *)enc;
    fill_img(e, i420);
    vpx_enc_frame_flags_t flags = force_kf ? VPX_EFLAG_FORCE_KF : 0;
    if (vpx_codec_encode(&e->ctx, &e->img, e->frame_index, 1, flags, VPX_DL_REALTIME))
        return -1;
    e->frame_index++;
    vpx_codec_iter_t iter = NULL;
    return drain(e, &iter, out, out_size, is_kf) ? 1 : 0;
}

// Flush the encoder (feed NULL until drained). Call repeatedly until it
// returns 0.
int sk_vpxenc_flush(void *enc, const uint8_t **out, size_t *out_size, int *is_kf) {
    sk_vpxenc *e = (sk_vpxenc *)enc;
    if (vpx_codec_encode(&e->ctx, NULL, e->frame_index, 1, 0, VPX_DL_REALTIME))
        return -1;
    vpx_codec_iter_t iter = NULL;
    return drain(e, &iter, out, out_size, is_kf) ? 1 : 0;
}

void sk_vpxenc_close(void *enc) {
    sk_vpxenc *e = (sk_vpxenc *)enc;
    if (!e) return;
    vpx_img_free(&e->img);
    vpx_codec_destroy(&e->ctx);
    free(e->pkt);
    free(e);
}

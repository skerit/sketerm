// Minimal C shim over libx264 — same role as src/winstream/sck_shim.m:
// wrap a fat third-party C API behind a few plain functions so the Zig
// side (src/wlhost/vcodec.zig x264 backend) calls it via extern fn,
// without dragging x264.h through the @cImport sets. Compiled + linked
// only on native builds with libx264 present (build.zig: addVideo,
// gated on build_options.video). Encodes full-range I420 as low-latency
// H.264 (ultrafast/zerolatency, Annex-B) for the per-tile video path.

#include <stdint.h> // x264.h requires the integer types to be visible first
#include <stdlib.h>
#include <string.h>
#include <x264.h>

typedef struct {
    x264_t *h;
    x264_picture_t pic_in;
    int width;
    int height;
} sk_x264;

// Open an encoder for a width×height I420 tile stream. Returns NULL on
// failure. `fps` <= 0 defaults to 30.
void *sk_x264_open(int width, int height, int fps) {
    x264_param_t param;
    if (x264_param_default_preset(&param, "ultrafast", "zerolatency") < 0) return NULL;
    param.i_log_level = X264_LOG_NONE; // no stderr spam in the daemon / tests
    param.i_width = width;
    param.i_height = height;
    param.i_csp = X264_CSP_I420;
    param.i_fps_num = (fps > 0) ? (unsigned)fps : 30;
    param.i_fps_den = 1;
    param.i_keyint_max = 120;        // periodic keyframes also aid UDP recovery
    param.b_repeat_headers = 1;      // SPS/PPS in every keyframe → self-contained
    param.b_annexb = 1;              // start-code NAL stream (one contiguous blob)
    param.rc.i_rc_method = X264_RC_CRF;
    param.rc.f_rf_constant = 24.0f;
    param.vui.b_fullrange = 1;       // we feed full-range BT.601 (see yuv.zig)
    if (x264_param_apply_profile(&param, "baseline") < 0) return NULL;

    x264_t *h = x264_encoder_open(&param);
    if (!h) return NULL;

    sk_x264 *e = (sk_x264 *)calloc(1, sizeof(sk_x264));
    if (!e) { x264_encoder_close(h); return NULL; }
    e->h = h;
    e->width = width;
    e->height = height;
    if (x264_picture_alloc(&e->pic_in, X264_CSP_I420, width, height) < 0) {
        x264_encoder_close(h);
        free(e);
        return NULL;
    }
    return e;
}

// Encode one I420 frame (tight y / u / v planes). On a frame emitted,
// returns its byte length, sets *out to the Annex-B blob (valid until
// the next encode call) and *is_kf to 1 for a keyframe. Returns 0 when
// the frame was buffered (no output), < 0 on error.
int sk_x264_encode(void *enc, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                   int force_kf, const uint8_t **out, int *is_kf) {
    sk_x264 *e = (sk_x264 *)enc;
    const int w = e->width, h = e->height;
    const int cw = w / 2, ch = h / 2;

    for (int r = 0; r < h; r++)
        memcpy(e->pic_in.img.plane[0] + (size_t)r * e->pic_in.img.i_stride[0], y + (size_t)r * w, w);
    for (int r = 0; r < ch; r++) {
        memcpy(e->pic_in.img.plane[1] + (size_t)r * e->pic_in.img.i_stride[1], u + (size_t)r * cw, cw);
        memcpy(e->pic_in.img.plane[2] + (size_t)r * e->pic_in.img.i_stride[2], v + (size_t)r * cw, cw);
    }
    e->pic_in.i_type = force_kf ? X264_TYPE_IDR : X264_TYPE_AUTO;

    x264_nal_t *nals = NULL;
    int i_nals = 0;
    x264_picture_t pic_out;
    int frame_size = x264_encoder_encode(e->h, &nals, &i_nals, &e->pic_in, &pic_out);
    if (frame_size < 0) return -1;
    if (frame_size == 0 || i_nals == 0) return 0;
    *out = nals[0].p_payload; // Annex-B: NALs are contiguous from here
    *is_kf = (pic_out.i_type == X264_TYPE_IDR || pic_out.i_type == X264_TYPE_I) ? 1 : 0;
    return frame_size;
}

void sk_x264_close(void *enc) {
    sk_x264 *e = (sk_x264 *)enc;
    if (!e) return;
    x264_picture_clean(&e->pic_in);
    if (e->h) x264_encoder_close(e->h);
    free(e);
}

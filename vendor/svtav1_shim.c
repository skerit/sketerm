// Minimal C shim over SVT-AV1 (libSvtAv1Enc) — the royalty-free AV1
// encoder of the video-tile path, the AV1 counterpart of x264_shim.c.
// The Zig side (src/wlhost/vcodec.zig Svt) calls it via extern fn.
//
// Talks to SVT-AV1 DIRECTLY rather than through libavcodec: the encoder
// runs inside the session daemon, and libSvtAv1Enc depends on libc/libm
// only, whereas libavcodec drags GLib, X11 and dozens of codecs into the
// process. Like every codec here it is RUNTIME-LOADED: compiled against
// EbSvtAv1Enc.h (build.zig addVideo, headers only), bound by
// `sk_svt_bind` from a handle vcodec.zig dlopen'd as
// `libSvtAv1Enc.so.<SVT_AV1_VERSION_MAJOR>`, so sketerm-mux keeps its
// libc-only ELF graph and a host without SVT-AV1 never offers AV1.
//
// Low-delay configuration (pred-struct=1, no lookahead): in that mode
// svt_av1_enc_get_packet BLOCKS until the picture just sent is encoded,
// so a frame in is a packet out, the property the tile stream needs.

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <EbSvtAv1Enc.h> // include dir from pkg-config SvtAv1Enc

#ifndef SVT_AV1_CHECK_VERSION
#define SVT_AV1_CHECK_VERSION(major, minor, patch) 0
#endif

#if SVT_AV1_CHECK_VERSION(3, 0, 0)
typedef EbErrorType (*init_handle_fn)(EbComponentType **, EbSvtAv1EncConfiguration *);
#else
typedef EbErrorType (*init_handle_fn)(EbComponentType **, void *, EbSvtAv1EncConfiguration *);
#endif

static struct {
    int bound;
    init_handle_fn init_handle;
    EbErrorType (*set_parameter)(EbComponentType *, EbSvtAv1EncConfiguration *);
    EbErrorType (*parse_parameter)(EbSvtAv1EncConfiguration *, const char *, const char *);
    EbErrorType (*init)(EbComponentType *);
    EbErrorType (*send_picture)(EbComponentType *, EbBufferHeaderType *);
    EbErrorType (*get_packet)(EbComponentType *, EbBufferHeaderType **, uint8_t);
    void (*release_out_buffer)(EbBufferHeaderType **);
    EbErrorType (*deinit)(EbComponentType *);
    EbErrorType (*deinit_handle)(EbComponentType *);
} S;

int sk_svt_major(void) { return SVT_AV1_VERSION_MAJOR; }

#if SVT_AV1_CHECK_VERSION(4, 0, 0)
// Only errors reach stderr: SVT's info banner (CPU flags, config dump)
// would otherwise print on every encoder open inside the daemon.
static void quiet_log(void *ctx, SvtAv1LogLevel level, const char *tag, const char *fmt, va_list args) {
    (void)ctx;
    if (level > SVT_AV1_LOG_ERROR) return;
    fprintf(stderr, "svt-av1 %s: ", tag ? tag : "");
    vfprintf(stderr, fmt, args);
}
#endif

int sk_svt_bind(void *h) {
    if (S.bound) return 1;
    if (!h) return 0;
    S.init_handle = (init_handle_fn)dlsym(h, "svt_av1_enc_init_handle");
    S.set_parameter = dlsym(h, "svt_av1_enc_set_parameter");
    S.parse_parameter = dlsym(h, "svt_av1_enc_parse_parameter");
    S.init = dlsym(h, "svt_av1_enc_init");
    S.send_picture = dlsym(h, "svt_av1_enc_send_picture");
    S.get_packet = dlsym(h, "svt_av1_enc_get_packet");
    S.release_out_buffer = dlsym(h, "svt_av1_enc_release_out_buffer");
    S.deinit = dlsym(h, "svt_av1_enc_deinit");
    S.deinit_handle = dlsym(h, "svt_av1_enc_deinit_handle");
    if (!S.init_handle || !S.set_parameter || !S.parse_parameter || !S.init || !S.send_picture ||
        !S.get_packet || !S.release_out_buffer || !S.deinit || !S.deinit_handle)
        return 0;
#if SVT_AV1_CHECK_VERSION(4, 0, 0)
    void (*set_log)(SvtAv1LogCallback, void *) = dlsym(h, "svt_av1_set_log_callback");
    if (set_log) set_log(quiet_log, NULL);
#endif
    S.bound = 1;
    return 1;
}

typedef struct {
    EbComponentType *h;
    int width;
    int height;
    int64_t pts;
    uint8_t *out;
    size_t out_cap;
} sk_svt;

void sk_svt_close(void *enc);

// Optional knobs go through parse_parameter by NAME, which is stable
// across SVT-AV1 releases where struct fields were renamed; one a given
// release does not know is skipped rather than failing the open.
static void knob(EbSvtAv1EncConfiguration *cfg, const char *name, const char *value) {
    (void)S.parse_parameter(cfg, name, value);
}

// Open an encoder for a width×height I420 tile stream (full-range 8-bit
// 4:2:0, what yuv.zig produces). NULL on failure or an unbound library.
void *sk_svt_open(int width, int height, int fps) {
    if (!S.bound) return NULL;
    sk_svt *e = (sk_svt *)calloc(1, sizeof(sk_svt));
    if (!e) return NULL;
    EbSvtAv1EncConfiguration cfg;
    memset(&cfg, 0, sizeof(cfg));
#if SVT_AV1_CHECK_VERSION(3, 0, 0)
    if (S.init_handle(&e->h, &cfg) != EB_ErrorNone) { free(e); return NULL; }
#else
    if (S.init_handle(&e->h, NULL, &cfg) != EB_ErrorNone) { free(e); return NULL; }
#endif
    e->width = width;
    e->height = height;
    cfg.source_width = (uint32_t)width;
    cfg.source_height = (uint32_t)height;
    cfg.frame_rate_numerator = (uint32_t)((fps > 0) ? fps : 30);
    cfg.frame_rate_denominator = 1;
    cfg.encoder_bit_depth = 8;
    cfg.enc_mode = 12; // fastest practical preset: real-time screen content
    knob(&cfg, "pred-struct", "1"); // low delay: no reordering, 1 in -> 1 out
    knob(&cfg, "lookahead", "0");
    knob(&cfg, "enable-tpl-la", "0");
    knob(&cfg, "keyint", "120"); // periodic keyframes, like x264's keyint_max
    knob(&cfg, "rc", "0");
    knob(&cfg, "crf", "35");
    knob(&cfg, "color-range", "1"); // we feed full-range BT.601 (yuv.zig)
    knob(&cfg, "lp", "1"); // bound the per-surface thread count
    if (S.set_parameter(e->h, &cfg) != EB_ErrorNone) goto fail;
    if (S.init(e->h) != EB_ErrorNone) goto fail;
    return e;
fail:
    S.deinit_handle(e->h);
    free(e);
    return NULL;
}

// Encode one tight I420 frame. On a packet, returns its size, sets *out
// (valid until the next encode call) and *is_kf. 0 = no packet, < 0 on
// error.
int sk_svt_encode(void *enc, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                  int force_kf, const uint8_t **out, int *is_kf) {
    sk_svt *e = (sk_svt *)enc;
    EbSvtIOFormat io;
    memset(&io, 0, sizeof(io));
    io.luma = (uint8_t *)y;
    io.cb = (uint8_t *)u;
    io.cr = (uint8_t *)v;
    io.y_stride = (uint32_t)e->width;
    io.cb_stride = (uint32_t)(e->width / 2);
    io.cr_stride = (uint32_t)(e->width / 2);

    EbBufferHeaderType in;
    memset(&in, 0, sizeof(in));
    in.size = sizeof(in);
    in.p_buffer = (uint8_t *)&io;
    in.n_filled_len = (uint32_t)(e->width * e->height + 2 * (e->width / 2) * (e->height / 2));
    in.n_alloc_len = in.n_filled_len;
    in.pts = e->pts++;
    in.pic_type = force_kf ? EB_AV1_KEY_PICTURE : EB_AV1_INVALID_PICTURE;
    if (S.send_picture(e->h, &in) != EB_ErrorNone) return -1;

    EbBufferHeaderType *pkt = NULL;
    EbErrorType r = S.get_packet(e->h, &pkt, 0);
    if (r == EB_NoErrorEmptyQueue || !pkt) return 0;
    if (r != EB_ErrorNone) return -1;
    size_t n = pkt->n_filled_len;
    if (n > e->out_cap) {
        uint8_t *grown = (uint8_t *)realloc(e->out, n);
        if (!grown) { S.release_out_buffer(&pkt); return -1; }
        e->out = grown;
        e->out_cap = n;
    }
    memcpy(e->out, pkt->p_buffer, n);
    *is_kf = (pkt->pic_type == EB_AV1_KEY_PICTURE || pkt->pic_type == EB_AV1_INTRA_ONLY_PICTURE) ? 1 : 0;
    S.release_out_buffer(&pkt);
    *out = e->out;
    return (int)n;
}

void sk_svt_close(void *enc) {
    sk_svt *e = (sk_svt *)enc;
    if (!e) return;
    if (e->h) {
        // Signal end of stream and drain, the shutdown SVT expects
        // (otherwise it warns on every encoder teardown).
        EbBufferHeaderType eos;
        memset(&eos, 0, sizeof(eos));
        eos.size = sizeof(eos);
        eos.flags = EB_BUFFERFLAG_EOS;
        eos.pic_type = EB_AV1_INVALID_PICTURE;
        if (S.send_picture(e->h, &eos) == EB_ErrorNone) {
            for (int i = 0; i < 64; i++) {
                EbBufferHeaderType *pkt = NULL;
                if (S.get_packet(e->h, &pkt, 1) != EB_ErrorNone || !pkt) break;
                int last = (pkt->flags & EB_BUFFERFLAG_EOS) != 0;
                S.release_out_buffer(&pkt);
                if (last) break;
            }
        }
        S.deinit(e->h);
        S.deinit_handle(e->h);
    }
    free(e->out);
    free(e);
}

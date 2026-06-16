// VideoToolbox H.264 encoder shim — the macOS-native counterpart to
// x264_shim.c. Same C ABI shape so vcodec.zig's VideoToolbox backend
// calls it via extern fn. Produces Annex-B H.264 (SPS/PPS in EVERY
// keyframe, start-code NALs) framed identically to the x264 path, so the
// existing libavcodec decoder (avdec_shim.c) reads it unchanged. No
// external deps — VideoToolbox is a system framework — so the native Mac
// daemon gets hardware video encode WITHOUT libx264/libavcodec.
//
// Input is tight I420 planes (Y, U, V), matching the x264/avenc backends;
// repacked into an NV12 full-range CVPixelBuffer (the format the encoder
// accepts) before encode. Full-range BT.601 throughout, the same space
// yuv.zig uses, so the decode round-trip matches the x264 path.

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    VTCompressionSessionRef session;
    int width, height;
    int fps;
    int64_t frame_index;
    // Annex-B output of the most recent encode, grown as needed. Written
    // by the (synchronous, post-CompleteFrames) output callback.
    uint8_t *out;
    size_t out_len, out_cap;
    int is_kf;
    int had_output;
    int err;
} sk_vt;

static const uint8_t kStartCode[4] = {0, 0, 0, 1};

static void out_append(sk_vt *e, const uint8_t *p, size_t n) {
    if (e->out_len + n > e->out_cap) {
        size_t cap = e->out_cap ? e->out_cap : 65536;
        while (cap < e->out_len + n) cap *= 2;
        uint8_t *nb = (uint8_t *)realloc(e->out, cap);
        if (!nb) { e->err = 1; return; }
        e->out = nb;
        e->out_cap = cap;
    }
    memcpy(e->out + e->out_len, p, n);
    e->out_len += n;
}

// AVCC sample (length-prefixed NALs, params in the format desc) → Annex-B
// (start-code NALs), prepending SPS/PPS on keyframes, into e->out.
static void emit_annexb(sk_vt *e, CMSampleBufferRef sb) {
    int keyframe = 1;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef not_sync = NULL;
        if (CFDictionaryGetValueIfPresent(d, kCMSampleAttachmentKey_NotSync, (const void **)&not_sync) &&
            not_sync && CFBooleanGetValue(not_sync))
            keyframe = 0;
    }
    e->is_kf = keyframe;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    int nal_len = 4;
    if (keyframe && fmt) {
        size_t count = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, &nal_len) == noErr) {
            for (size_t i = 0; i < count; i++) {
                const uint8_t *ps = NULL;
                size_t ps_size = 0;
                if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &ps_size, NULL, NULL) == noErr && ps) {
                    out_append(e, kStartCode, 4);
                    out_append(e, ps, ps_size);
                }
            }
        }
    } else if (fmt) {
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, NULL, &nal_len);
    }
    if (nal_len <= 0 || nal_len > 4) nal_len = 4;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) { e->err = 1; return; }
    size_t total = 0, at_off = 0;
    char *data = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, &at_off, &total, &data) != noErr || !data) { e->err = 1; return; }
    if (at_off < total) total = at_off; // only the contiguous head is addressable
    size_t off = 0;
    while (off + (size_t)nal_len <= total) {
        uint32_t nlen = 0;
        for (int i = 0; i < nal_len; i++) nlen = (nlen << 8) | (uint8_t)data[off + i];
        off += (size_t)nal_len;
        if (nlen == 0 || off + nlen > total) break;
        out_append(e, kStartCode, 4);
        out_append(e, (const uint8_t *)data + off, nlen);
        off += nlen;
    }
}

static void out_cb(void *refcon, void *src, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    (void)src;
    (void)flags;
    sk_vt *e = (sk_vt *)refcon;
    if (status != noErr || !sb || !CMSampleBufferDataIsReady(sb)) return;
    emit_annexb(e, sb);
    e->had_output = 1;
}

static void set_num(VTCompressionSessionRef s, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    VTSessionSetProperty(s, key, n);
    CFRelease(n);
}

// Open an H.264 encoder for width×height tiles at `fps` (<=0 → 30).
// Even dims required. Returns NULL on failure.
void *sk_vtenc_open(int width, int height, int fps) {
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1)) return NULL;
    if (fps <= 0) fps = 30;
    sk_vt *e = (sk_vt *)calloc(1, sizeof(sk_vt));
    if (!e) return NULL;
    e->width = width;
    e->height = height;
    e->fps = fps;

    // Prefer the hardware encoder; VideoToolbox falls back to software if
    // unavailable (it just won't be required-HW).
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    OSStatus st = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
                                             spec, NULL, NULL, out_cb, e, &e->session);
    CFRelease(spec);
    if (st != noErr || !e->session) {
        free(e);
        return NULL;
    }

    // Low-latency, no-reorder, periodic keyframes — matching the x264
    // ultrafast/zerolatency baseline configuration.
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    set_num(e->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, 120);
    // ~0.12 bits/pixel/frame, floored so tiny tiles still get a usable rate.
    double bps = (double)width * (double)height * (double)fps * 0.12;
    int bitrate = (bps > 2.0e9) ? 2000000000 : (int)bps;
    if (bitrate < 200000) bitrate = 200000;
    set_num(e->session, kVTCompressionPropertyKey_AverageBitRate, bitrate);
    VTCompressionSessionPrepareToEncodeFrames(e->session);
    return e;
}

// Encode one tight I420 frame. On output returns the Annex-B length (>0)
// and sets *out (valid until the next encode) + *is_kf; 0 when nothing was
// emitted, <0 on error.
int sk_vtenc_encode(void *enc, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                    int force_kf, const uint8_t **out, int *is_kf) {
    sk_vt *e = (sk_vt *)enc;
    if (!e || !e->session) return -1;
    const int w = e->width, h = e->height, cw = w / 2, ch = h / 2;

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &pb) != kCVReturnSuccess || !pb)
        return -1;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *cp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < h; r++)
        memcpy(yp + (size_t)r * ys, y + (size_t)r * w, (size_t)w);
    // I420 (separate U,V planes) → NV12 (interleaved CbCr plane).
    for (int r = 0; r < ch; r++) {
        uint8_t *dst = cp + (size_t)r * cs;
        const uint8_t *ur = u + (size_t)r * cw;
        const uint8_t *vr = v + (size_t)r * cw;
        for (int x = 0; x < cw; x++) {
            dst[2 * x] = ur[x];
            dst[2 * x + 1] = vr[x];
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CFDictionaryRef props = NULL;
    if (force_kf) {
        const void *k[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void *vv[] = {kCFBooleanTrue};
        props = CFDictionaryCreate(NULL, k, vv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }

    e->out_len = 0;
    e->had_output = 0;
    e->err = 0;
    CMTime pts = CMTimeMake(e->frame_index, e->fps);
    CMTime dur = CMTimeMake(1, e->fps);
    e->frame_index++;
    OSStatus st = VTCompressionSessionEncodeFrame(e->session, pb, pts, dur, props, NULL, NULL);
    if (props) CFRelease(props);
    CVPixelBufferRelease(pb);
    if (st != noErr) return -1;
    // Force synchronous emission of this frame (no lookahead buffering).
    VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
    if (e->err) return -1;
    if (!e->had_output || e->out_len == 0) return 0;
    *out = e->out;
    *is_kf = e->is_kf;
    return (int)e->out_len;
}

void sk_vtenc_close(void *enc) {
    sk_vt *e = (sk_vt *)enc;
    if (!e) return;
    if (e->session) {
        VTCompressionSessionInvalidate(e->session);
        CFRelease(e->session);
    }
    free(e->out);
    free(e);
}

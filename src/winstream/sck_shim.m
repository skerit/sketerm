// ScreenCaptureKit window-stream shim — the Darwin half of
// winstream/sck.zig, plain C ABI so Zig needs no ObjC bridging.
//
// Threading: the daemon is a single-threaded poll loop, but SCK
// delivers frames and shareable-content callbacks on its own
// dispatch queues. Everything mutable lives behind one mutex;
// callbacks buffer state and poke the wakeup pipe; the daemon
// thread consumes it all via sketerm_sck_drain().
//
// Window tracking: SCShareableContent is re-fetched at most every
// 500ms; windows are matched to the session by pid ancestry (the
// session's PTY child and its descendants) OR by controlling
// terminal (catches apps that re-parent to launchd after the
// spawning shell exits). One SCStream per window, BGRA at point
// resolution, latest-frame-wins buffering.
//
// Input: CGEventPost at the HID tap. Window-local pixel coords are
// mapped through the tracked SCWindow frame (both are top-left
// origin global points). Needs the Accessibility TCC grant; the
// Screen Recording grant gates capture. Missing grants surface
// through sketerm_sck_status / sketerm_sck_last_error — the Zig
// side turns them into a visible notice, never a silent hang.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ApplicationServices/ApplicationServices.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

typedef struct {
    uint32_t kind; // 0 open, 1 frame, 2 title, 3 close
    uint32_t win;
    int32_t w, h;
    const uint8_t *data; // BGRA pixels (tight) or UTF-8 title
    size_t len;
} SckEvent;

// ── per-window state ────────────────────────────────────────────

@interface SketermSckWin : NSObject {
@public
    uint32_t win_id;
    pid_t pid;
    CGRect rect; // global points, top-left origin
    SCStream *stream;
    id out; // SCStreamOutput delegate (retained alongside stream)
    NSString *title;
    // Frame double-buffer: callbacks write `latest`; drain copies
    // into `snap`, which stays valid until the NEXT drain.
    uint8_t *latest;
    size_t latest_cap;
    int32_t fw, fh;
    BOOL dirty;
    uint8_t *snap;
    size_t snap_cap;
    BOOL closing;
}
@end

@implementation SketermSckWin
- (void)dealloc {
    free(latest);
    free(snap);
}
@end

// ── context ─────────────────────────────────────────────────────

@interface SketermSckCtx : NSObject {
@public
    pthread_mutex_t mu;
    pid_t root_pid;
    dev_t root_tdev; // controlling terminal of the session child
    NSMutableDictionary<NSNumber *, SketermSckWin *> *wins;
    // Lifecycle events queued by the refresh callback:
    // @{@"kind", @"win", @"w", @"h", @"title"}.
    NSMutableArray<NSDictionary *> *pending;
    int pipe_r, pipe_w;
    dispatch_queue_t frame_q;
    BOOL refresh_inflight;
    uint64_t last_refresh_ms;
    BOOL fetch_ok; // at least one shareable-content fetch succeeded
    BOOL dead;
    char err[512];
    // Drain scratch (owned here, valid until the next drain).
    SckEvent *ev_scratch;
    size_t ev_cap;
    NSMutableArray *drain_hold; // NSData backing title/open bytes
    // Pointer-injection state.
    uint32_t btn_mask;
    double last_click_t;
    CGPoint last_click_at;
    int click_state;
    double scroll_acc_x, scroll_acc_y;
    BOOL ax_prompted;
}
@end

@implementation SketermSckCtx
@end

typedef struct SckCtx SckCtx; // opaque alias for the bridged object

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)(ts.tv_nsec / 1000000);
}

static void set_err(SketermSckCtx *c, NSString *msg) {
    // Caller holds the mutex.
    strncpy(c->err, msg.UTF8String ?: "unknown error", sizeof(c->err) - 1);
    c->err[sizeof(c->err) - 1] = 0;
}

static void wake(SketermSckCtx *c) {
    char b = 'w';
    (void)!write(c->pipe_w, &b, 1);
}

static bool proc_info(pid_t pid, pid_t *ppid, dev_t *tdev) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return false;
    if (ppid) *ppid = kp.kp_eproc.e_ppid;
    if (tdev) *tdev = kp.kp_eproc.e_tdev;
    return true;
}

/// Window owner belongs to the session: descendant of the PTY
/// child, or shares its controlling terminal (apps re-parented to
/// launchd after the shell exec'd or exited keep the tty).
static bool pid_in_session(SketermSckCtx *c, pid_t pid) {
    dev_t tdev;
    if (proc_info(pid, NULL, &tdev)) {
        if (c->root_tdev != (dev_t)-1 && tdev == c->root_tdev) return true;
    }
    pid_t p = pid;
    for (int i = 0; i < 32 && p > 1; i++) {
        if (p == c->root_pid) return true;
        pid_t parent;
        if (!proc_info(p, &parent, NULL)) return false;
        p = parent;
    }
    return false;
}

// ── frame output delegate ───────────────────────────────────────

@interface SketermSckOut : NSObject <SCStreamOutput> {
@public
    __weak SketermSckCtx *ctx;
    SketermSckWin *win; // strong: outlives dict removal until stream stops
}
@end

@implementation SketermSckOut
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sb
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    SketermSckCtx *c = ctx;
    if (!c) return;

    // Only complete frames carry pixels worth copying.
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    CGRect content = CGRectNull;
    double scale = 1.0;
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *a = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        NSNumber *status = a[SCStreamFrameInfoStatus];
        if (status && status.intValue != SCFrameStatusComplete) return;
        NSDictionary *rectDict = a[SCStreamFrameInfoContentRect];
        if (rectDict) {
            CGRect r;
            if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rectDict, &r))
                content = r;
        }
        NSNumber *sf = a[SCStreamFrameInfoScaleFactor];
        if (sf) scale = sf.doubleValue;
    }

    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    size_t bw = CVPixelBufferGetWidth(img);
    size_t bh = CVPixelBufferGetHeight(img);
    size_t stride = CVPixelBufferGetBytesPerRow(img);
    const uint8_t *base = CVPixelBufferGetBaseAddress(img);
    if (base && bw > 0 && bh > 0) {
        // Crop to the content rect (the window may have resized
        // since the stream config was set — SCK letterboxes).
        size_t x0 = 0, y0 = 0, cw = bw, ch = bh;
        if (!CGRectIsNull(content) && content.size.width > 1 && content.size.height > 1) {
            x0 = (size_t)(content.origin.x * scale);
            y0 = (size_t)(content.origin.y * scale);
            cw = (size_t)(content.size.width * scale);
            ch = (size_t)(content.size.height * scale);
            if (x0 >= bw) x0 = 0;
            if (y0 >= bh) y0 = 0;
            if (x0 + cw > bw) cw = bw - x0;
            if (y0 + ch > bh) ch = bh - y0;
        }
        pthread_mutex_lock(&c->mu);
        SketermSckWin *w = win;
        if (!c->dead && w && !w->closing) {
            size_t need = cw * ch * 4;
            if (w->latest_cap < need) {
                free(w->latest);
                w->latest = malloc(need);
                w->latest_cap = w->latest ? need : 0;
            }
            if (w->latest) {
                for (size_t y = 0; y < ch; y++)
                    memcpy(w->latest + y * cw * 4, base + (y0 + y) * stride + x0 * 4, cw * 4);
                w->fw = (int32_t)cw;
                w->fh = (int32_t)ch;
                w->dirty = YES;
                wake(c);
            }
        }
        pthread_mutex_unlock(&c->mu);
    }
    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}
@end

// ── window refresh ──────────────────────────────────────────────

static void start_stream(SketermSckCtx *c, SketermSckWin *sw, SCWindow *scw) {
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.width = (size_t)MAX(scw.frame.size.width, 32.0);
    cfg.height = (size_t)MAX(scw.frame.size.height, 32.0);
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.minimumFrameInterval = CMTimeMake(1, 30);
    cfg.showsCursor = NO;
    cfg.queueDepth = 3;
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:scw];
    SketermSckOut *out = [SketermSckOut new];
    out->ctx = c;
    out->win = sw;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
    NSError *err = nil;
    [stream addStreamOutput:out type:SCStreamOutputTypeScreen sampleHandlerQueue:c->frame_q error:&err];
    sw->stream = stream;
    sw->out = out;
    [stream startCaptureWithCompletionHandler:^(NSError *e) {
        if (!e) return;
        pthread_mutex_lock(&c->mu);
        set_err(c, [NSString stringWithFormat:@"window capture failed to start: %@", e.localizedDescription]);
        pthread_mutex_unlock(&c->mu);
        wake(c);
    }];
}

static void apply_content(SketermSckCtx *c, SCShareableContent *content) {
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *pid_cache = [NSMutableDictionary dictionary];

    for (SCWindow *scw in content.windows) {
        if (scw.windowLayer != 0) continue; // normal app windows only
        if (scw.frame.size.width < 16 || scw.frame.size.height < 16) continue;
        pid_t wpid = scw.owningApplication.processID;
        NSNumber *cached = pid_cache[@(wpid)];
        bool mine = cached ? cached.boolValue : pid_in_session(c, wpid);
        if (!cached) pid_cache[@(wpid)] = @(mine);
        if (!mine) continue;

        NSNumber *key = @(scw.windowID);
        [seen addObject:key];
        SketermSckWin *sw = c->wins[key];
        NSString *title = scw.title ?: @"";
        if (!sw) {
            sw = [SketermSckWin new];
            sw->win_id = scw.windowID;
            sw->pid = wpid;
            sw->rect = scw.frame;
            sw->title = title;
            c->wins[key] = sw;
            [c->pending addObject:@{
                @"kind" : @0,
                @"win" : key,
                @"w" : @((int32_t)scw.frame.size.width),
                @"h" : @((int32_t)scw.frame.size.height),
                @"title" : title.length ? title : (scw.owningApplication.applicationName ?: @"remote app"),
            }];
            start_stream(c, sw, scw);
        } else {
            BOOL resized = fabs(sw->rect.size.width - scw.frame.size.width) > 1.0 ||
                fabs(sw->rect.size.height - scw.frame.size.height) > 1.0;
            sw->rect = scw.frame;
            if (![sw->title isEqualToString:title] && title.length > 0) {
                sw->title = title;
                [c->pending addObject:@{ @"kind" : @2, @"win" : key, @"title" : title }];
            }
            if (resized && sw->stream) {
                SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
                cfg.width = (size_t)MAX(scw.frame.size.width, 32.0);
                cfg.height = (size_t)MAX(scw.frame.size.height, 32.0);
                cfg.pixelFormat = kCVPixelFormatType_32BGRA;
                cfg.minimumFrameInterval = CMTimeMake(1, 30);
                cfg.showsCursor = NO;
                cfg.queueDepth = 3;
                [sw->stream updateConfiguration:cfg completionHandler:^(NSError *e){ (void)e; }];
            }
        }
    }

    // Anything tracked but gone from the on-screen list closed (or
    // minimized — close it client-side; it re-opens when it returns).
    for (NSNumber *key in c->wins.allKeys) {
        if ([seen containsObject:key]) continue;
        SketermSckWin *sw = c->wins[key];
        if (sw->closing) continue;
        sw->closing = YES;
        [sw->stream stopCaptureWithCompletionHandler:^(NSError *e){ (void)e; }];
        [c->pending addObject:@{ @"kind" : @3, @"win" : key }];
    }
}

static void kick_refresh(SketermSckCtx *c, uint64_t now) {
    // Caller holds the mutex.
    if (c->refresh_inflight || c->dead) return;
    if (c->fetch_ok && now - c->last_refresh_ms < 500) return;
    c->refresh_inflight = YES;
    c->last_refresh_ms = now;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                onScreenWindowsOnly:YES
                                                  completionHandler:^(SCShareableContent *content, NSError *error) {
        pthread_mutex_lock(&c->mu);
        c->refresh_inflight = NO;
        if (c->dead) {
            pthread_mutex_unlock(&c->mu);
            return;
        }
        if (error) {
            set_err(c, [NSString stringWithFormat:@"shareable-content fetch failed: %@ — is Screen Recording granted and a GUI session logged in?", error.localizedDescription]);
        } else {
            c->fetch_ok = YES;
            apply_content(c, content);
        }
        pthread_mutex_unlock(&c->mu);
        wake(c);
    }];
}

// ── C API ───────────────────────────────────────────────────────

SckCtx *sketerm_sck_create(int32_t root_pid) {
    SketermSckCtx *c = [SketermSckCtx new];
    if (!c) return NULL;
    pthread_mutex_init(&c->mu, NULL);
    c->root_pid = root_pid;
    c->root_tdev = (dev_t)-1;
    dev_t tdev;
    if (proc_info(root_pid, NULL, &tdev) && tdev != (dev_t)-1) c->root_tdev = tdev;
    c->wins = [NSMutableDictionary dictionary];
    c->pending = [NSMutableArray array];
    c->drain_hold = [NSMutableArray array];
    c->frame_q = dispatch_queue_create("sketerm.sck.frames", DISPATCH_QUEUE_SERIAL);
    int fds[2];
    if (pipe(fds) != 0) return NULL;
    c->pipe_r = fds[0];
    c->pipe_w = fds[1];
    fcntl(c->pipe_r, F_SETFL, O_NONBLOCK);
    fcntl(c->pipe_w, F_SETFL, O_NONBLOCK);
    fcntl(c->pipe_r, F_SETFD, FD_CLOEXEC);
    fcntl(c->pipe_w, F_SETFD, FD_CLOEXEC);

    if (!CGPreflightScreenCaptureAccess()) {
        // Triggers the one-time system prompt (needs a logged-in GUI
        // session); the grant applies to THIS binary and requires a
        // daemon restart to take effect.
        CGRequestScreenCaptureAccess();
        pthread_mutex_lock(&c->mu);
        set_err(c, @"Screen Recording not granted: System Settings → Privacy & Security → Screen Recording → enable sketerm-mux, then restart the daemon");
        pthread_mutex_unlock(&c->mu);
    }
    kick_refresh(c, now_ms());
    return (SckCtx *)CFBridgingRetain(c);
}

void sketerm_sck_destroy(SckCtx *ctx) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    pthread_mutex_lock(&c->mu);
    c->dead = YES;
    for (SketermSckWin *sw in c->wins.allValues)
        [sw->stream stopCaptureWithCompletionHandler:^(NSError *e){ (void)e; }];
    [c->wins removeAllObjects];
    pthread_mutex_unlock(&c->mu);
    // Flush in-flight frame callbacks before tearing down.
    dispatch_sync(c->frame_q, ^{});
    close(c->pipe_r);
    close(c->pipe_w);
    CFBridgingRelease(ctx);
}

int sketerm_sck_wakeup_fd(SckCtx *ctx) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    return c->pipe_r;
}

uint32_t sketerm_sck_status(SckCtx *ctx) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    uint32_t st = 0;
    if (CGPreflightScreenCaptureAccess()) st |= 1;
    if (AXIsProcessTrusted()) st |= 2;
    pthread_mutex_lock(&c->mu);
    if (c->fetch_ok) st |= 4;
    if (c->err[0]) st |= 8;
    pthread_mutex_unlock(&c->mu);
    return st;
}

size_t sketerm_sck_last_error(SckCtx *ctx, char *buf, size_t cap) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    pthread_mutex_lock(&c->mu);
    size_t n = strnlen(c->err, sizeof(c->err));
    if (n > cap) n = cap;
    memcpy(buf, c->err, n);
    c->err[0] = 0;
    pthread_mutex_unlock(&c->mu);
    return n;
}

const SckEvent *sketerm_sck_drain(SckCtx *ctx, size_t *out_n) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    char junk[256];
    while (read(c->pipe_r, junk, sizeof(junk)) > 0) {
    }

    pthread_mutex_lock(&c->mu);
    // Purge windows whose close event was consumed by the PREVIOUS
    // drain — their buffers are no longer referenced.
    NSMutableArray *gone = [NSMutableArray array];
    for (NSNumber *key in c->wins.allKeys) {
        SketermSckWin *sw = c->wins[key];
        if (sw->closing) {
            BOOL still_pending = NO;
            for (NSDictionary *p in c->pending)
                if ([p[@"win"] isEqual:key]) still_pending = YES;
            if (!still_pending) [gone addObject:key];
        }
    }
    for (NSNumber *key in gone) [c->wins removeObjectForKey:key];

    kick_refresh(c, now_ms());

    [c->drain_hold removeAllObjects];
    size_t cap_needed = c->pending.count + c->wins.count;
    if (c->ev_cap < cap_needed) {
        free(c->ev_scratch);
        c->ev_scratch = malloc(cap_needed * sizeof(SckEvent));
        c->ev_cap = c->ev_scratch ? cap_needed : 0;
    }
    size_t n = 0;
    if (c->ev_scratch) {
        for (NSDictionary *p in c->pending) {
            if (n >= c->ev_cap) break;
            SckEvent *e = &c->ev_scratch[n++];
            memset(e, 0, sizeof(*e));
            e->kind = [p[@"kind"] unsignedIntValue];
            e->win = [p[@"win"] unsignedIntValue];
            e->w = [p[@"w"] intValue];
            e->h = [p[@"h"] intValue];
            NSString *title = p[@"title"];
            if (title) {
                NSData *d = [title dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
                [c->drain_hold addObject:d];
                e->data = d.bytes;
                e->len = d.length;
            }
        }
        for (SketermSckWin *sw in c->wins.allValues) {
            if (!sw->dirty || sw->closing || n >= c->ev_cap) continue;
            size_t need = (size_t)sw->fw * 4 * (size_t)sw->fh;
            if (sw->snap_cap < need) {
                free(sw->snap);
                sw->snap = malloc(need);
                sw->snap_cap = sw->snap ? need : 0;
            }
            if (!sw->snap) continue;
            memcpy(sw->snap, sw->latest, need);
            sw->dirty = NO;
            SckEvent *e = &c->ev_scratch[n++];
            e->kind = 1;
            e->win = sw->win_id;
            e->w = sw->fw;
            e->h = sw->fh;
            e->data = sw->snap;
            e->len = need;
        }
    }
    [c->pending removeAllObjects];
    pthread_mutex_unlock(&c->mu);
    *out_n = n;
    return c->ev_scratch;
}

// ── input injection ─────────────────────────────────────────────

static void ensure_ax(SketermSckCtx *c) {
    if (AXIsProcessTrusted()) return;
    pthread_mutex_lock(&c->mu);
    BOOL first = !c->ax_prompted;
    c->ax_prompted = YES;
    if (first)
        set_err(c, @"input dropped: Accessibility not granted — System Settings → Privacy & Security → Accessibility → enable sketerm-mux");
    pthread_mutex_unlock(&c->mu);
    if (first) {
        NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        wake(c);
    }
}

static SketermSckWin *win_by_id(SketermSckCtx *c, uint32_t win) {
    // Caller holds the mutex.
    return c->wins[@(win)];
}

static void activate_app(pid_t pid) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app && !app.active) [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

void sketerm_sck_key(SckCtx *ctx, uint32_t win, uint16_t keycode, bool down, uint64_t flags) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    ensure_ax(c);
    pthread_mutex_lock(&c->mu);
    SketermSckWin *sw = win_by_id(c, win);
    pid_t pid = sw ? sw->pid : 0;
    pthread_mutex_unlock(&c->mu);
    if (pid && down) activate_app(pid);
    CGEventRef ev = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keycode, down);
    if (!ev) return;
    CGEventSetFlags(ev, (CGEventFlags)flags);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

void sketerm_sck_ptr(SckCtx *ctx, uint32_t win, uint8_t kind, double x, double y, uint32_t detail) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    ensure_ax(c);
    pthread_mutex_lock(&c->mu);
    SketermSckWin *sw = win_by_id(c, win);
    if (!sw) {
        pthread_mutex_unlock(&c->mu);
        return;
    }
    // Frame pixels → global points through the live window frame.
    double sx = sw->fw > 0 ? sw->rect.size.width / (double)sw->fw : 1.0;
    double sy = sw->fh > 0 ? sw->rect.size.height / (double)sw->fh : 1.0;
    CGPoint at = CGPointMake(sw->rect.origin.x + x * sx, sw->rect.origin.y + y * sy);

    CGEventType type;
    CGMouseButton button = kCGMouseButtonLeft;
    int clicks = 1;
    if (kind == 0) { // move / drag
        if (c->btn_mask & 1) {
            type = kCGEventLeftMouseDragged;
        } else if (c->btn_mask & 4) {
            type = kCGEventRightMouseDragged;
            button = kCGMouseButtonRight;
        } else if (c->btn_mask) {
            type = kCGEventOtherMouseDragged;
            button = kCGMouseButtonCenter;
        } else {
            type = kCGEventMouseMoved;
        }
    } else { // press / release; detail is the X11 button number
        bool downp = kind == 1;
        switch (detail) {
        case 3:
            type = downp ? kCGEventRightMouseDown : kCGEventRightMouseUp;
            button = kCGMouseButtonRight;
            break;
        case 2:
            type = downp ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
            button = kCGMouseButtonCenter;
            break;
        default:
            type = downp ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
            break;
        }
        uint32_t bit = detail == 3 ? 4 : detail == 2 ? 2 : 1;
        if (downp) {
            c->btn_mask |= bit;
            // Double-click detection: nearby + quick re-press.
            double t = now_ms() / 1000.0;
            if (t - c->last_click_t < 0.4 && fabs(at.x - c->last_click_at.x) < 4 &&
                fabs(at.y - c->last_click_at.y) < 4) {
                c->click_state++;
            } else {
                c->click_state = 1;
            }
            c->last_click_t = t;
            c->last_click_at = at;
        } else {
            c->btn_mask &= ~bit;
        }
        clicks = c->click_state;
    }
    pthread_mutex_unlock(&c->mu);

    CGEventRef ev = CGEventCreateMouseEvent(NULL, type, at, button);
    if (!ev) return;
    if (kind != 0) CGEventSetIntegerValueField(ev, kCGMouseEventClickState, clicks);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

void sketerm_sck_scroll(SckCtx *ctx, uint32_t win, double dx, double dy) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    (void)win;
    ensure_ax(c);
    pthread_mutex_lock(&c->mu);
    // GTK: positive dy = content scrolls down; CG wheel axis 1 is
    // positive-up. Accumulate fractions so trackpad smooth deltas
    // aren't dropped.
    c->scroll_acc_y += -dy;
    c->scroll_acc_x += -dx;
    int32_t ticks_y = (int32_t)c->scroll_acc_y;
    int32_t ticks_x = (int32_t)c->scroll_acc_x;
    c->scroll_acc_y -= ticks_y;
    c->scroll_acc_x -= ticks_x;
    pthread_mutex_unlock(&c->mu);
    if (ticks_y == 0 && ticks_x == 0) return;
    if (ticks_y > 10) ticks_y = 10;
    if (ticks_y < -10) ticks_y = -10;
    if (ticks_x > 10) ticks_x = 10;
    if (ticks_x < -10) ticks_x = -10;
    CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, ticks_y, ticks_x);
    if (!ev) return;
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

void sketerm_sck_close_win(SckCtx *ctx, uint32_t win) {
    SketermSckCtx *c = (__bridge SketermSckCtx *)ctx;
    pthread_mutex_lock(&c->mu);
    SketermSckWin *sw = win_by_id(c, win);
    pid_t pid = sw ? sw->pid : 0;
    CGRect rect = sw ? sw->rect : CGRectZero;
    size_t app_windows = 0;
    if (sw)
        for (SketermSckWin *o in c->wins.allValues)
            if (o->pid == pid && !o->closing) app_windows++;
    pthread_mutex_unlock(&c->mu);
    if (!pid) return;

    if (AXIsProcessTrusted()) {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        CFArrayRef axwins = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&axwins) == kAXErrorSuccess && axwins) {
            for (CFIndex i = 0; i < CFArrayGetCount(axwins); i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(axwins, i);
                AXValueRef posv = NULL, sizev = NULL;
                CGPoint pos = CGPointZero;
                CGSize size = CGSizeZero;
                if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, (CFTypeRef *)&posv) == kAXErrorSuccess && posv) {
                    AXValueGetValue(posv, kAXValueTypeCGPoint, &pos);
                    CFRelease(posv);
                }
                if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, (CFTypeRef *)&sizev) == kAXErrorSuccess && sizev) {
                    AXValueGetValue(sizev, kAXValueTypeCGSize, &size);
                    CFRelease(sizev);
                }
                if (fabs(pos.x - rect.origin.x) > 8 || fabs(pos.y - rect.origin.y) > 8 ||
                    fabs(size.width - rect.size.width) > 8 || fabs(size.height - rect.size.height) > 8)
                    continue;
                AXUIElementRef btn = NULL;
                if (AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute, (CFTypeRef *)&btn) == kAXErrorSuccess && btn) {
                    AXUIElementPerformAction(btn, kAXPressAction);
                    CFRelease(btn);
                    CFRelease(axwins);
                    CFRelease(app);
                    return;
                }
            }
            CFRelease(axwins);
        }
        CFRelease(app);
    }
    // No AX path: closing the app's ONLY window degrades to a
    // graceful app termination; multi-window apps keep running.
    if (app_windows <= 1) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [app terminate];
    }
}

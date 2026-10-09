#ifndef SK_WEB_UNTRUSTED_H
#define SK_WEB_UNTRUSTED_H

#include "include/capi/cef_resource_request_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Append-only: values are reported to the denied callback and mapped by Zig. */
enum sk_web_untrusted_reason {
    /* Resolved to a private, special-purpose or this host's own address. */
    SK_WEB_UNTRUSTED_PRIVATE = 1,
    SK_WEB_UNTRUSTED_UNSUPPORTED = 2,
    SK_WEB_UNTRUSTED_BROKER_FAILURE = 3,
    /* The per-request deadline passed, time spent queued included. */
    SK_WEB_UNTRUSTED_TIMEOUT = 4,
    /* MAX_JOBS loads were active and QUEUE_CAP more were already waiting. */
    SK_WEB_UNTRUSTED_QUEUE_FULL = 5
};

/* Plain decimal so translate-c yields integer constants for the Zig side. */
#define SK_WEB_UNTRUSTED_MAX_JOBS 16
#define SK_WEB_UNTRUSTED_QUEUE_CAP 256
#define SK_WEB_UNTRUSTED_TIMEOUT_MS 15000
#define SK_WEB_UNTRUSTED_URL_CAP 8192
#define SK_WEB_UNTRUSTED_HEADER_CAP 65536
#define SK_WEB_UNTRUSTED_HEADER_FIELDS 256
#define SK_WEB_UNTRUSTED_UPLOAD_CAP 1048576
#define SK_WEB_UNTRUSTED_BODY_CAP 16777216

/* All int functions return 1 on success, 0 on refusal; non-Linux fails closed. */
/* RLIMIT_CORE 0/0 only; inherited, and leaves Chromium's namespace sandbox usable. */
int sk_web_untrusted_core_limit(void);
/* PR_SET_DUMPABLE 0 only; exec can reset it, and it forbids writing the
 * process's own uid_map, so not for processes that build a user namespace. */
int sk_web_untrusted_nondumpable(void);
/* Both of the above; the broker and its jobs use this. */
int sk_web_untrusted_no_core(void);
/* Call before threads/CEF, with an existing, owned, canonical 0700 directory;
 * start/stop are single-owner lifecycle operations, not concurrent factories.
 * Requires Linux x86_64/aarch64, close_range and libcurl >= 7.85 with TLS.
 */
int sk_web_untrusted_start(const char *private_dir);
/* 1 when the running broker confines each job with Landlock (no filesystem
 * writes/creation/exec, TCP limited to the target port and DNS); best-effort,
 * so 0 on kernels without Landlock while loads keep working. */
int sk_web_untrusted_job_landlock(void);
/* Irreversible, process-wide (TSYNC), inherited across fork/exec; call before CEF.
 * Applies the core limit but leaves dumpable untouched for Chromium's sandbox. */
int sk_web_untrusted_confine(void);
/* Call outside CEF callbacks, before cef_shutdown; joins outstanding loader work. */
void sk_web_untrusted_stop(void);

/* Borrows the UI-thread navigation request; resource requests have different IDs. */
void sk_web_untrusted_navigation(cef_request_t *request, cef_frame_t *frame, int browser_id, int user_gesture);

/* Borrows all arguments, copies stateless callbacks and trusted CEF metadata, and returns
 * one owned reference; NULL leaves disable_default_handling in force. */
cef_resource_request_handler_t *sk_web_untrusted_request_handler(
    const cef_resource_request_handler_t *callbacks, cef_request_t *request,
    int is_navigation, int is_download, const cef_string_t *request_initiator);

/* Reports one refused load. unsent is 1 when the loader refused before handing the
 * request to the broker (nothing left the process), 0 when the broker answered with a
 * refusal and the request may have been sent. request_id is CEF's request identifier. */
typedef void (*sk_web_untrusted_denied_fn)(int cef_browser_id, uint64_t request_id, int reason, int unsent);

/* Borrows request/metadata; returns one owned handler reference, including for refusals.
 * NULL is a refusal, never permission to fall back to CEF networking.
 * denied must be thread-safe, nonblocking, and live until stop returns; it may
 * run on the factory/open thread or a loader thread, never for cancellation.
 * CEF supplies Cookie/Set-Cookie for navigation/same-origin requests; cross-origin
 * static loads strip both plus Referer, and curl has no cookie/auth store.
 * The caller must gate every request, service worker, prefetch and redirect,
 * disable CEF DNS, and use a separate helper process from trusted views.
 * This confines hostile page JS, not compromised native code or AF_UNIX IPC.
 * Limits (constants above): 16 active loads, then a FIFO of 256 waiting ones; 15s
 * per request from open, queueing included; 8KiB URL, 64KiB/256 request header
 * fields, 64KiB response headers, 1MiB upload, 16MiB decoded response, buffered.
 * Authority comes only from sk_web_untrusted_request_handler's CEF metadata.
 * GET/HEAD navigation and same-origin GET/HEAD/POST are supported. Cross-origin
 * GET scripts/styles/fonts require credential-free transport, matching MIME
 * and exactly one ACAO: *. All other cross-origin kinds and all non-navigation
 * redirects fail closed: CEF cannot express Fetch response tainting here.
 * Worker HTTP loads are refused even same-origin; navigation responses add worker-src
 * 'none'. Empty/null initiators cannot load HTTP subresources because CEF gives
 * blob-worker imports the same RT_SCRIPT/frame attribution as document scripts.
 * No ranges, file uploads, authentication, CONNECT or upgrades. A request body is
 * only the BYTES elements CEF hands over: CEF reports a data-pipe body (Blob, File,
 * ReadableStream) as an EMPTY element without flagging it excluded, so any EMPTY
 * element refuses the load rather than sending a body with the part missing.
 */
cef_resource_handler_t *sk_web_untrusted_resource(
    cef_request_t *request, const cef_resource_request_handler_t *metadata, int allow_private,
    sk_web_untrusted_denied_fn denied, int cef_browser_id);

#ifdef __cplusplus
}
#endif
#endif

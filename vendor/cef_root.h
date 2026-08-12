// Translation root for the Chromium Embedded Framework C API, turned
// into the `cef` Zig module by build.zig's `fetch-cef`-gated TranslateC
// step. Only reachable from the optional `sketerm-web` helper — the
// GUI, the daemon and the tests never see a CEF header.
//
// Unlike `cimport_root.h` this needs no shim include path and no sed
// fixup: the capi headers are plain C and translate clean.
//
// The `-I` handed to translate-c is the ROOT of the binary distribution
// (`$XDG_CACHE_HOME/sketerm/cef/<version>/`), which is why every include
// below is spelled with its `include/` prefix — that is how CEF's own
// headers include each other.

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_accessibility_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_values_capi.h"
// a11y: `cef_write_json` powers the SKETERM_WEB_AX_DEBUG raw-payload
// dump (the accessibility handler's value shapes were verified with it).
#include "include/capi/cef_parser_capi.h"
// Semantic layer: the render-process side runs in the SAME binary (CEF
// re-execs it as its own renderer subprocess), so the V8 and
// process-message APIs belong to this translation unit too.
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_frame_capi.h"
// WebExtensions: the `chrome-extension://<host>/` origin is a custom
// scheme (registered from the app in EVERY process) served by our own
// resource handler over the unpacked extension directory. Without a
// real origin an ES-module background page cannot load at all — a
// static `import` is a fetch, and nothing answers a url no scheme
// handler serves.
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
// Filter-list subscription: the helper is the only process in this
// project with an HTTPS stack (the daemon links libc only), so keeping
// an EasyList subscription current has to happen here. A urlrequest
// rather than a view, because a `.txt` navigated to is RENDERED, not
// downloaded.
#include "include/capi/cef_urlrequest_capi.h"
#include "include/cef_version.h"

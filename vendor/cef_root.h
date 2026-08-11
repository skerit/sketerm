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
#include "include/cef_version.h"

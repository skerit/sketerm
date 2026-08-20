// Shim for translate-c on macOS, where the SDK ships no <uchar.h>.
//
// CEF's cef_string_types.h guards that include with
// `#ifdef __clang__ / #if __has_include(<uchar.h>)`, precisely because
// the header only exists with Xcode 14.3+. Zig's translate-c (Aro) does
// not define __clang__, so it takes the `#else` branch and includes
// <uchar.h> unconditionally — which fails on a Command Line Tools SDK.
//
// Supplying the two typedefs CEF actually needs is enough: it uses
// char16_t for cef_string_utf16_t and nothing else from the header.
// Shadows nothing on a host that HAS a real <uchar.h>, because this
// directory is only on the include path for the CEF translation.
#pragma once

#include <stdint.h>

#ifndef __cplusplus
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
#endif

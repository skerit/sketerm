// Test-only NSAccessibility probe — the harness half of
// smoke_a11y_macos.zig. Compiled ONLY into the `smoke-a11y` target,
// never into a shipping binary. It sends the real NSAccessibility
// selectors to a live SketermTermView (created by nsax_shim.m) — the
// exact methods VoiceOver / the Accessibility Inspector call — and
// marshals the answers back to Zig so the smoke can assert them. This
// exercises the full stack: ObjC method dispatch → a11y/nsax.zig
// callbacks → view.zig snapshot, including the codepoint↔UTF-16
// boundary, without needing a running app or the AppKit pane frontend.

#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint8_t *dup_nsstring(NSString *s, size_t *out_len) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    *out_len = d.length;
    if (d.length == 0) return NULL;
    uint8_t *buf = malloc(d.length);
    memcpy(buf, d.bytes, d.length);
    return buf;
}

int sketerm_axprobe_is_element(void *view_p) {
    id v = (__bridge id)view_p;
    return [v isAccessibilityElement] ? 1 : 0;
}

int sketerm_axprobe_role_is_textarea(void *view_p) {
    id v = (__bridge id)view_p;
    return [[v accessibilityRole] isEqualToString:NSAccessibilityTextAreaRole] ? 1 : 0;
}

uint8_t *sketerm_axprobe_value(void *view_p, size_t *out_len) {
    id v = (__bridge id)view_p;
    return dup_nsstring([v accessibilityValue], out_len);
}

long sketerm_axprobe_num_chars(void *view_p) {
    id v = (__bridge id)view_p;
    return (long)[v accessibilityNumberOfCharacters];
}

void sketerm_axprobe_caret(void *view_p, size_t *out_loc, size_t *out_len) {
    id v = (__bridge id)view_p;
    NSRange r = [v accessibilitySelectedTextRange];
    *out_loc = r.location;
    *out_len = r.length;
}

uint8_t *sketerm_axprobe_string_for_range(void *view_p, size_t loc, size_t len, size_t *out_len) {
    id v = (__bridge id)view_p;
    return dup_nsstring([v accessibilityStringForRange:NSMakeRange(loc, len)], out_len);
}

long sketerm_axprobe_line_for_index(void *view_p, size_t idx) {
    id v = (__bridge id)view_p;
    return (long)[v accessibilityLineForIndex:(NSInteger)idx];
}

long sketerm_axprobe_insertion_line(void *view_p) {
    id v = (__bridge id)view_p;
    return (long)[v accessibilityInsertionPointLineNumber];
}

int sketerm_axprobe_range_for_line(void *view_p, long line, size_t *out_loc, size_t *out_len) {
    id v = (__bridge id)view_p;
    NSRange r = [v accessibilityRangeForLine:(NSInteger)line];
    if (r.location == NSNotFound) return 0;
    *out_loc = r.location;
    *out_len = r.length;
    return 1;
}

long sketerm_axprobe_visible_len(void *view_p) {
    id v = (__bridge id)view_p;
    NSRange r = [v accessibilityVisibleCharacterRange];
    return (long)(r.location == NSNotFound ? -1 : (long)r.length);
}

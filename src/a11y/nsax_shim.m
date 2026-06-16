// macOS NSAccessibility bridge — the AppKit half of a11y/nsax.zig.
//
// Two host objects share one set of text-protocol answers (the static
// `ax_*` helpers below, which call the Zig bridge a11y/nsax.zig):
//
//   * `SketermTermView : NSView` — for the future native AppKit pane,
//     where the pane IS an NSView and reports itself as the text area.
//   * `SketermTermAXElement : NSAccessibilityElement` — for the CURRENT
//     GTK-on-macOS frontend, where panes are GtkGLAreas with no per-pane
//     NSView. GTK4 has no NSAccessibility backend at all (only AT-SPI,
//     unavailable on macOS), so the window's single GdkMacos content
//     NSView exposes one of these elements per pane as an accessibility
//     child — that is what reaches VoiceOver.
//
// macOS has no terminal role, so both report NSAccessibilityTextAreaRole
// (what Terminal.app / iTerm2 use). Plain C ABI so Zig needs no ObjC
// bridging, matching winstream/sck_shim.m. NSRange/NSString are UTF-16
// code units; the Zig side translates to/from the snapshot's codepoint
// offsets, so everything crossing this boundary is already UTF-16.
// Strings from the Zig callbacks are malloc'd UTF-8 freed here.

#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <stdint.h>

// ── Zig callbacks (a11y/nsax.zig export fns) ────────────────────────
extern uint8_t  *sketerm_nsax_value(void *term, size_t *out_len);
extern size_t    sketerm_nsax_length(void *term);
extern uint8_t  *sketerm_nsax_string_for_range(void *term, size_t loc, size_t len, size_t *out_len);
extern size_t    sketerm_nsax_caret(void *term);
extern long long sketerm_nsax_line_for_index(void *term, size_t index);
extern int       sketerm_nsax_range_for_line(void *term, long long line, size_t *out_loc, size_t *out_len);

// Take ownership of a malloc'd UTF-8 buffer from the Zig side, copy it
// into an NSString, and free it. NULL (empty) → @"".
static NSString *take_utf8(uint8_t *p, size_t len) {
    if (!p) return @"";
    NSString *s = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
    free(p);
    return s ?: @"";
}

// ── shared text-protocol answers (both host objects call these) ─────

static id ax_value(void *term) {
    size_t len = 0;
    return take_utf8(sketerm_nsax_value(term, &len), len);
}
static NSInteger ax_num_chars(void *term) {
    return (NSInteger)sketerm_nsax_length(term);
}
static id ax_string_for_range(void *term, NSRange r) {
    if (r.location == NSNotFound) return @"";
    size_t len = 0;
    return take_utf8(sketerm_nsax_string_for_range(term, r.location, r.length, &len), len);
}
static NSRange ax_visible_range(void *term) {
    return NSMakeRange(0, sketerm_nsax_length(term));
}
static NSRange ax_selected_range(void *term) {
    return NSMakeRange(sketerm_nsax_caret(term), 0);
}
static NSInteger ax_insertion_line(void *term) {
    long long l = sketerm_nsax_line_for_index(term, sketerm_nsax_caret(term));
    return l < 0 ? 0 : (NSInteger)l;
}
static NSInteger ax_line_for_index(void *term, NSInteger index) {
    long long l = sketerm_nsax_line_for_index(term, index < 0 ? 0 : (size_t)index);
    return l < 0 ? 0 : (NSInteger)l;
}
static NSRange ax_range_for_line(void *term, NSInteger line) {
    size_t loc = 0, len = 0;
    if (sketerm_nsax_range_for_line(term, (long long)line, &loc, &len))
        return NSMakeRange(loc, len);
    return NSMakeRange(NSNotFound, 0);
}

// ── SketermTermView : NSView (future AppKit pane) ───────────────────

@interface SketermTermView : NSView {
@private
    void *_term; // stable *Terminal; deref term.screen live on the Zig side
}
- (void)setSketermTerminal:(void *)term;
@end

@implementation SketermTermView
- (void)setSketermTerminal:(void *)term { _term = term; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (id)accessibilityValue { return ax_value(_term); }
- (NSInteger)accessibilityNumberOfCharacters { return ax_num_chars(_term); }
- (NSString *)accessibilityStringForRange:(NSRange)r { return ax_string_for_range(_term, r); }
- (NSRange)accessibilityVisibleCharacterRange { return ax_visible_range(_term); }
- (NSRange)accessibilitySelectedTextRange { return ax_selected_range(_term); }
- (NSString *)accessibilitySelectedText { return @""; }
- (NSInteger)accessibilityInsertionPointLineNumber { return ax_insertion_line(_term); }
- (NSInteger)accessibilityLineForIndex:(NSInteger)i { return ax_line_for_index(_term, i); }
- (NSRange)accessibilityRangeForLine:(NSInteger)l { return ax_range_for_line(_term, l); }
- (NSRect)accessibilityFrameForRange:(NSRange)r { (void)r; return NSZeroRect; }
@end

// ── SketermTermAXElement : NSAccessibilityElement (GTK content view) ─

@interface SketermTermAXElement : NSAccessibilityElement {
@private
    void *_term;
}
- (void)setSketermTerminal:(void *)term;
@end

@implementation SketermTermAXElement
- (void)setSketermTerminal:(void *)term { _term = term; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (id)accessibilityValue { return ax_value(_term); }
- (NSInteger)accessibilityNumberOfCharacters { return ax_num_chars(_term); }
- (NSString *)accessibilityStringForRange:(NSRange)r { return ax_string_for_range(_term, r); }
- (NSRange)accessibilityVisibleCharacterRange { return ax_visible_range(_term); }
- (NSRange)accessibilitySelectedTextRange { return ax_selected_range(_term); }
- (NSString *)accessibilitySelectedText { return @""; }
- (NSInteger)accessibilityInsertionPointLineNumber { return ax_insertion_line(_term); }
- (NSInteger)accessibilityLineForIndex:(NSInteger)i { return ax_line_for_index(_term, i); }
- (NSRange)accessibilityRangeForLine:(NSInteger)l { return ax_range_for_line(_term, l); }
@end

// ── C ABI: SketermTermView factory (future AppKit pane) ─────────────

void *sketerm_nsax_new_view(void *term) {
    SketermTermView *v = [[SketermTermView alloc] initWithFrame:NSZeroRect];
    [v setSketermTerminal:term];
    return (__bridge_retained void *)v;
}

void sketerm_nsax_set_terminal(void *view, void *term) {
    SketermTermView *v = (__bridge SketermTermView *)view;
    [v setSketermTerminal:term];
}

void sketerm_nsax_release_view(void *view) {
    SketermTermView *v = (__bridge_transfer SketermTermView *)view; // ARC -1
    (void)v;
}

// ── C ABI: GTK content-view attachment (current frontend) ───────────

// The NSWindow's content NSView (GtkMacosContentView). No ownership
// change — the window owns it.
void *sketerm_nsax_content_view(void *nswindow) {
    if (!nswindow) return NULL;
    NSWindow *w = (__bridge NSWindow *)nswindow;
    return (__bridge void *)[w contentView];
}

// Create a pane element bound to `term` and add it as an accessibility
// child of `content_view`. Returns a +1-retained element; balance it
// with sketerm_nsax_detach.
void *sketerm_nsax_attach(void *content_view, void *term) {
    if (!content_view) return NULL;
    NSView *cv = (__bridge NSView *)content_view;
    SketermTermAXElement *el = [[SketermTermAXElement alloc] init];
    [el setSketermTerminal:term];
    [el setAccessibilityParent:cv];
    NSArray *cur = [cv accessibilityChildren];
    NSMutableArray *kids = cur ? [cur mutableCopy] : [NSMutableArray array];
    [kids addObject:el];
    [cv setAccessibilityChildren:kids];
    return (__bridge_retained void *)el;
}

void sketerm_nsax_detach(void *content_view, void *element) {
    if (!element) return;
    SketermTermAXElement *el = (__bridge_transfer SketermTermAXElement *)element; // ARC -1
    if (content_view) {
        NSView *cv = (__bridge NSView *)content_view;
        NSArray *cur = [cv accessibilityChildren];
        if (cur) {
            NSMutableArray *kids = [cur mutableCopy];
            [kids removeObjectIdenticalTo:el];
            [cv setAccessibilityChildren:kids];
        }
    }
    [el setAccessibilityParent:nil];
}

// Position the element within its parent (content view) coordinate
// space. GTK widget coords are top-left origin; AppKit's parent space
// is bottom-left unless the parent view is flipped (GtkMacosContentView
// is). Flip only if needed so the frame is right either way.
void sketerm_nsax_set_frame_in_parent(void *element, double x, double y, double w, double h) {
    if (!element) return;
    id el = (__bridge id)element;
    NSRect frame = NSMakeRect(x, y, w, h);
    id parent = [el accessibilityParent];
    if ([parent isKindOfClass:[NSView class]] && ![(NSView *)parent isFlipped]) {
        frame.origin.y = [(NSView *)parent bounds].size.height - (y + h);
    }
    [el setAccessibilityFrameInParentSpace:frame];
}

// ── C ABI: change notification + self-check ─────────────────────────

// Tell AT clients (VoiceOver) the value + caret changed; works on a
// SketermTermView or a SketermTermAXElement alike. Cheap — clients
// re-query on demand.
void sketerm_nsax_notify_changed(void *obj) {
    if (!obj) return;
    id o = (__bridge id)obj;
    NSAccessibilityPostNotification(o, NSAccessibilityValueChangedNotification);
    NSAccessibilityPostNotification(o, NSAccessibilitySelectedTextChangedNotification);
}

// In-process wiring check (needs no TCC grant): returns a bitmask —
// bit0 element is among the content view's accessibility children,
// bit1 its role is AXTextArea, bit2 its value is non-empty. 7 = a
// VoiceOver client walking window→contentView→child would find an
// AXTextArea whose value is the live terminal text.
int sketerm_nsax_selfcheck(void *content_view, void *element) {
    if (!content_view || !element) return 0;
    NSView *cv = (__bridge NSView *)content_view;
    id el = (__bridge id)element;
    int r = 0;
    if ([[cv accessibilityChildren] containsObject:el]) r |= 1;
    if ([[el accessibilityRole] isEqualToString:NSAccessibilityTextAreaRole]) r |= 2;
    NSString *v = [el accessibilityValue];
    if (v && v.length > 0) r |= 4;
    return r;
}

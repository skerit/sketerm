// NSApplication bootstrap for the macOS browser helper.
//
// CEF's macOS message pump runs on top of Cocoa: browser-process tasks
// on the UI thread are dispatched through the application's run loop,
// and `cef_do_message_loop_work` pumps THAT. CEF also REQUIRES the
// application object to implement CefAppProtocol — Chromium re-enters
// the event loop in places and asks the application whether it is
// currently inside a `sendEvent:` dispatch; an NSApplication that
// cannot answer trips a CHECK inside CEF the first time it matters.
// Both are documented CEF contract for any macOS embedder, which is why
// this exists.
//
// HONEST LIMIT, so nobody credits this with more than it earned: this
// was written to explain the open "no load-finished after navigate"
// failure, and IT DID NOT FIX IT. The stall is unchanged with and
// without this file. It is kept because the contract above is real and
// the helper must satisfy it either way — not because it is a proven
// fix for anything yet observed. See docs/cef-macos.md.
//
// Declared in C rather than importing any CEF header: the protocol is
// two selectors, and keeping this file CEF-free means the helper's ObjC
// side has no build dependency on the distribution's headers.

#import <Cocoa/Cocoa.h>

// The two selectors CefAppProtocol declares. Implemented here on our
// own application subclass, which is all CEF looks for at runtime.
@interface SketermWebApplication : NSApplication {
@private
    BOOL handlingSendEvent_;
}
- (BOOL)isHandlingSendEvent;
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

@implementation SketermWebApplication

- (BOOL)isHandlingSendEvent {
    return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    handlingSendEvent_ = handlingSendEvent;
}

// Chromium sets the flag around its own dispatch; mirroring it here
// keeps the answer above honest for events that arrive by other routes.
- (void)sendEvent:(NSEvent*)event {
    BOOL was = handlingSendEvent_;
    handlingSendEvent_ = YES;
    [super sendEvent:event];
    handlingSendEvent_ = was;
}

@end

/// Create the shared application instance, before cef_initialize.
///
/// `sharedApplication` on OUR subclass is what makes NSApp an instance
/// of it — the first call wins, so this must run before anything else
/// (CEF included) touches NSApp. Deliberately does NOT call `run`: the
/// helper owns its own loop and drives Cocoa through
/// `cef_do_message_loop_work`.
///
/// The activation policy is `Prohibited` — this process is a background
/// renderer host with no UI of its own, and without this it would take
/// a Dock icon and steal focus the moment it starts.
void sketerm_web_init_nsapp(void) {
    @autoreleasepool {
        [SketermWebApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    }
}

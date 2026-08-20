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

// [NSApp isRunning] is deliberately NOT overridden. Faking YES routes
// every UI-thread run loop through the "pull events until quit" branch
// of Chromium's MessagePumpNSApplication::DoRun, which measurably
// broke windowless_frame_rate pacing (view_max_fps 30 -> ~10
// paints/s, smoke-web stage 19); external_message_pump=1 time-slices
// nested runs and stalled page loads the same way. See
// docs/cef-macos.md for the full pump-flavor matrix.

@end

// The socket loop's lifeline inside AppKit-owned run loops.
//
// Chromium code on the UI thread is free to enter a nested run loop,
// and with an honest [NSApp isRunning] the first nested
// base::RunLoop::Run bootstraps [NSApp run] — which can then keep
// running as THE application loop instead of returning to the poll
// loop in server.zig (measured: main thread parked in
// -[NSApplication run] on the first subresource-bearing page load,
// helper frozen, smoke-web stage 22d). Chromium itself stays healthy
// inside that loop; the only casualty is our socket serving. So the
// server registers one repeating CFRunLoopTimer on the MAIN run loop
// (common modes — AppKit's nested loops run those) that performs one
// NON-BLOCKING server iteration. While the poll loop runs normally
// the timer's work is a cheap no-op-ish duplicate; the moment any
// [NSApp run] swallows the thread, the timer IS the server loop.
static CFRunLoopTimerRef g_iterate_timer;
static void (*g_iterate_cb)(void*);
static void* g_iterate_ctx;

static void iterate_timer_fire(CFRunLoopTimerRef timer, void* info) {
    (void)timer;
    (void)info;
    if (g_iterate_cb) g_iterate_cb(g_iterate_ctx);
}

void sketerm_web_add_iterate_timer(void (*cb)(void*), void* ctx) {
    g_iterate_cb = cb;
    g_iterate_ctx = ctx;
    if (g_iterate_timer) return;
    g_iterate_timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + 0.005, /*interval=*/0.005,
        /*flags=*/0, /*order=*/0, iterate_timer_fire, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_iterate_timer,
                      kCFRunLoopCommonModes);
}

void sketerm_web_remove_iterate_timer(void) {
    g_iterate_cb = NULL;
    g_iterate_ctx = NULL;
    if (!g_iterate_timer) return;
    CFRunLoopTimerInvalidate(g_iterate_timer);
    CFRelease(g_iterate_timer);
    g_iterate_timer = NULL;
}

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
/// Drain the main thread's CFRunLoop of everything already due —
/// sources and, crucially, TIMERS. Chromium parks its delayed work
/// (windowless frame pacing among it) on a CFRunLoopTimer attached to
/// this run loop, and with `isRunning` answering YES nothing else
/// spins the loop for it: `cef_do_message_loop_work` alone left those
/// timers firing at a ~100ms quantum, which turned `view_max_fps 30`
/// into ~10 paints/s (smoke-web stage 19 measured it). One
/// non-blocking pass per pump turn puts the timer wheel back on the
/// poll cadence.
void sketerm_web_pump_runloop(void) {
    @autoreleasepool {
        // Ready CFRunLoop sources and timers first...
        while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) ==
               kCFRunLoopRunHandledSource) {
        }
        // ...then the NSEvent QUEUE: Chromium's ScheduleWork posts an
        // application-defined NSEvent when the app "is running", and
        // events sit unprocessed unless somebody dequeues them.
        for (;;) {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event == nil) break;
            [NSApp sendEvent:event];
        }
    }
}

void sketerm_web_init_nsapp(void) {
    @autoreleasepool {
        [SketermWebApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    }
}

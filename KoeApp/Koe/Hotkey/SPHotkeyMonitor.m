#import "SPHotkeyMonitor.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SPHotkeyState) {
    SPHotkeyStateIdle,
    SPHotkeyStatePending,        // Trigger key pressed, waiting to determine tap vs hold
    SPHotkeyStateDoubleTapFirstDown, // First press is down; no audio starts yet
    SPHotkeyStateDoubleTapWaiting,   // First tap completed; waiting for second press
    SPHotkeyStateDoubleTapSecondDown, // Second press confirmed; pre-capture is active
    SPHotkeyStateRecordingHold,  // Confirmed hold, recording
    SPHotkeyStateRecordingToggle, // Confirmed tap, free-hands recording
    SPHotkeyStateDoubleTapStopPending, // Trigger is down; wait to rule out a shortcut
    SPHotkeyStateConsumeKeyUp,   // Waiting to consume keyUp after toggle-stop
};

@interface SPHotkeyMonitor ()

@property (nonatomic, weak) id<SPHotkeyMonitorDelegate> delegate;
@property (nonatomic, assign) SPHotkeyState state;
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, strong) NSTimer *doubleTapTimer;
@property (nonatomic, assign) BOOL triggerDown;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;
@property (nonatomic, strong) id globalMonitorRef;
@property (nonatomic, strong) id localMonitorRef;
@property (nonatomic, assign) BOOL running;
// The CGEventTap lives on this dedicated thread. Its callback gates every
// keyboard event in the session, so it must never run on the main thread:
// when the main thread stalls (ASR finalization, paste, overlay work —
// exactly when the user releases the trigger key), a main-thread tap
// swallows in-flight modifier events. WindowServer then accumulates stale
// modifier state for downstream consumers and emits corrective FlagsChanged
// events (keycode 63/Fn) when the tap is destroyed at quit — other apps'
// Fn-hotkey detectors see those as real presses (issues #57/#65).
@property (nonatomic, strong) NSThread *tapThread;
@property (nonatomic, assign) CFRunLoopRef tapRunLoop;
@property (nonatomic, strong) dispatch_semaphore_t tapShutdownSemaphore;
// Whether the current tap thread was started asking for an ACTIVE
// (consuming) tap. An active tap is only requested while something actually
// needs to swallow events: a non-modifier trigger key, or the template
// selector's number shortcuts. The rest of the time a LISTEN-ONLY tap is
// used: quitting Koe after long real-world use with a long-lived ACTIVE tap
// makes WindowServer emit phantom Fn FlagsChanged events at tap teardown
// (issues #57/#65) — a mechanism we could reproduce with Koe but never with
// short-lived or listen-only taps.
@property (nonatomic, assign) BOOL tapWantsActive;
@property (nonatomic, assign, readwrite) BOOL canConsumeGlobalKeyEvents;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedNumberKeyCodes;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedHotkeyKeyCodes;
@property (nonatomic, strong) dispatch_block_t pendingModifierReleaseBlock;

- (void)handleFlagsChangedEvent:(CGEventRef)event;
- (BOOL)handleNSEvent:(NSEvent *)event;
- (BOOL)isTargetKeyCode:(NSInteger)keyCode;
- (BOOL)isModifierOnlyMatchKind:(uint8_t)matchKind;
- (BOOL)keyModifiers:(NSUInteger)flags matchRequiredModifiers:(NSUInteger)requiredFlags;
- (BOOL)isRecordingState;
- (BOOL)hasUnconfirmedPreCapture;
- (BOOL)handleNumberKeyWithKeyCode:(NSInteger)keyCode;
- (BOOL)handleEnterKeyWithKeyCode:(NSInteger)keyCode;
- (BOOL)consumeSuppressedNumberKeyForKeyCode:(NSInteger)keyCode isKeyUp:(BOOL)isKeyUp;
- (BOOL)isSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber;
- (void)addSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber;
- (BOOL)removeSuppressedHotkeyKeyCodeIfPresent:(NSNumber *)keyCodeNumber;
- (void)tapThreadMain:(dispatch_semaphore_t)readySemaphore;
- (BOOL)needsEventConsumption;
- (void)startTapThread;
- (void)stopTapThread;
- (void)updateTapModeIfNeeded;
- (NSUInteger)currentModifierFlags;
- (void)cancelPendingModifierRelease;
- (void)scheduleModifierRelease;
- (void)cancelDoubleTapTimer;
- (void)cancelDoubleTapCandidateForInterveningInput;
- (void)handleTriggerDown;
- (void)handleTriggerUp;

@end

static NSInteger numberForKeyCode(NSInteger keyCode) {
    switch (keyCode) {
        case 18: return 1;
        case 19: return 2;
        case 20: return 3;
        case 21: return 4;
        case 23: return 5;
        case 22: return 6;
        case 26: return 7;
        case 28: return 8;
        case 25: return 9;
        default: return 0;
    }
}

static BOOL isReturnKeyCode(NSInteger keyCode) {
    return keyCode == 36 || keyCode == 76; // Return or keypad Enter
}

// Run a block on the main thread in kCFRunLoopCommonModes. Unlike
// dispatch_async(main queue), this also executes while the main run loop is
// in a modal or event-tracking mode (NSAlert, Sparkle update prompts, menu
// tracking) — the main dispatch queue is NOT drained during those loops, and
// trigger handling must not freeze whenever an alert happens to be on screen.
static void SPPerformOnMainRunLoop(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(mainRunLoop);
}

static const NSUInteger SPHotkeyRelevantModifierMask =
    NSEventModifierFlagCommand |
    NSEventModifierFlagOption |
    NSEventModifierFlagControl |
    NSEventModifierFlagShift |
    NSEventModifierFlagFunction;
static const CFTimeInterval SPModifierOnlyReleaseDebounceSeconds = 0.35;

// C callback for CGEventTap
static CGEventRef hotkeyEventCallback(CGEventTapProxy proxy,
                                       CGEventType type,
                                       CGEventRef event,
                                       void *userInfo) {
    SPHotkeyMonitor *monitor = (__bridge SPHotkeyMonitor *)userInfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Only re-enable the tap if we are still running.  During teardown
        // the tap may fire one last time — re-enabling it would race with
        // the CFRelease in -stop.
        if (monitor.running && monitor.eventTap) {
            CGEventTapEnable(monitor.eventTap, true);
        }
        return event;
    }

    if (!monitor.running || monitor.suspended) return event;

    if (type == kCGEventFlagsChanged) {
        [monitor handleFlagsChangedEvent:event];
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        NSNumber *keyCodeNumber = @(keyCode);
        NSUInteger flags = (NSUInteger)CGEventGetFlags(event);
        BOOL isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        BOOL suppressedTriggerKey = [monitor isSuppressedHotkeyKeyCode:keyCodeNumber];

        if ([monitor consumeSuppressedNumberKeyForKeyCode:keyCode isKeyUp:(type == kCGEventKeyUp)]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        if (isRepeat) {
            return event;
        }

        // A Command tap that becomes a real keyboard shortcut (for example
        // Command-C) must not count toward the double-tap gesture.
        if (type == kCGEventKeyDown && ![monitor isTargetKeyCode:keyCode]) {
            SPPerformOnMainRunLoop(^{
                [monitor cancelDoubleTapCandidateForInterveningInput];
            });
        }

        // Forward number keys 1-9 if handler is set.
        // When handled, suppress both keyDown and keyUp so the typed digit
        // does not leak into the user's target app.
        if (type == kCGEventKeyDown && [monitor handleNumberKeyWithKeyCode:keyCode]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        // Forward Return/Enter to accept the raw ASR result mid-correction.
        // When handled, suppress both keyDown and keyUp so the newline does
        // not leak into the user's target app.
        if (type == kCGEventKeyDown && [monitor handleEnterKeyWithKeyCode:keyCode]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        // Any keyDown (not handled by number keys above) dismisses the overlay.
        // The event is NOT consumed — it passes through to the target app.
        if (type == kCGEventKeyDown && monitor.anyKeyDismissHandler) {
            void (^handler)(void) = monitor.anyKeyDismissHandler;
            SPPerformOnMainRunLoop(^{
                handler();
            });
        }

        BOOL handlesModifierOnlyTrigger =
            [monitor isModifierOnlyMatchKind:monitor.targetMatchKind] &&
            [monitor isTargetKeyCode:keyCode];
        BOOL handlesKeyDownMatchedTrigger =
            ![monitor isModifierOnlyMatchKind:monitor.targetMatchKind] &&
            [monitor isTargetKeyCode:keyCode] &&
            ([monitor keyModifiers:flags matchRequiredModifiers:monitor.targetModifierFlag] ||
             (type == kCGEventKeyUp && suppressedTriggerKey));

        if (handlesModifierOnlyTrigger || handlesKeyDownMatchedTrigger) {
            NSLog(@"[Koe] Key event: type=%d keyCode=%ld", type, (long)keyCode);
            BOOL isDown = (type == kCGEventKeyDown);
            // Dedup and mutate triggerDown ON THE MAIN THREAD, not here. The
            // same physical event also arrives via the NSEvent monitor path
            // on the main thread; if the tap thread flips triggerDown ahead
            // of the main-thread state machine, a fast tap gets processed
            // twice (start + immediate stop). All edges must be decided
            // against triggerDown serially on main.
            SPPerformOnMainRunLoop(^{
                if (isDown == monitor.triggerDown) return;
                monitor.triggerDown = isDown;
                if (isDown) {
                    [monitor handleTriggerDown];
                } else {
                    [monitor handleTriggerUp];
                }
            });
            if (handlesKeyDownMatchedTrigger && isDown) {
                [monitor addSuppressedHotkeyKeyCode:keyCodeNumber];
                return NULL;
            }
            if (handlesKeyDownMatchedTrigger && suppressedTriggerKey) {
                [monitor removeSuppressedHotkeyKeyCodeIfPresent:keyCodeNumber];
                return NULL;
            }
        }

        if (type == kCGEventKeyUp && [monitor removeSuppressedHotkeyKeyCodeIfPresent:keyCodeNumber]) {
            return NULL;
        }
    }

    return event;
}

@implementation SPHotkeyMonitor

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _holdThresholdMs = 180.0;
        _doubleTapThresholdMs = NSEvent.doubleClickInterval * 1000.0;
        _state = SPHotkeyStateIdle;
        _triggerDown = NO;
        _targetKeyCode = 63;       // kVK_Function (Fn)
        _altKeyCode = 179;         // Globe key on newer keyboards
        _targetModifierFlag = 0x00800000; // NX_SECONDARYFNMASK
        _targetMatchKind = SPHotkeyMatchKindModifierOnly;
        _canConsumeGlobalKeyEvents = NO;
        _suppressedNumberKeyCodes = [NSMutableSet set];
        _suppressedHotkeyKeyCodes = [NSMutableSet set];
    }
    return self;
}

- (void)start {
    if (self.globalMonitorRef) return;
    self.running = YES;

    __weak typeof(self) weakSelf = self;

    // Use both global + local NSEvent monitors for maximum coverage.
    // Global monitor catches events when other apps are focused.
    // Local monitor catches events when our app (menu bar) is focused.
    self.globalMonitorRef = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                                  handler:^(NSEvent *event) {
        [weakSelf handleNSEvent:event];
    }];

    self.localMonitorRef = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                                handler:^NSEvent *(NSEvent *event) {
        return [weakSelf handleNSEvent:event] ? nil : event;
    }];

    NSLog(@"[Koe] Hotkey monitor started via NSEvent monitors (trigger=%ld/%ld flag=0x%lx kind=%u threshold=%.0fms)",
          (long)self.targetKeyCode,
          (long)self.altKeyCode,
          (unsigned long)self.targetModifierFlag,
          self.targetMatchKind,
          self.holdThresholdMs);

    // Also try CGEventTap as additional source, hosted on a dedicated thread
    // (see tapThread property for why it must never share the main thread).
    [self startTapThread];
}

- (BOOL)needsEventConsumption {
    // Modifier-only triggers (Fn, Option, …) never consume the trigger
    // events; only the template selector's number shortcuts and the raw-ASR
    // fallback's Enter accept need swallowing.
    // Non-modifier triggers consume their keyDown/keyUp so the trigger key
    // does not leak into the focused app.
    return ![self isModifierOnlyMatchKind:self.targetMatchKind] ||
           self.numberKeyHandler != nil ||
           self.enterKeyHandler != nil;
}

- (void)startTapThread {
    if (self.tapThread) return;
    self.tapWantsActive = [self needsEventConsumption];
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    self.tapShutdownSemaphore = dispatch_semaphore_create(0);
    NSThread *thread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(tapThreadMain:)
                                                 object:ready];
    thread.name = @"im.koe.hotkey-tap";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    self.tapThread = thread;
    [thread start];
    // Wait for the tap to be installed so canConsumeGlobalKeyEvents is
    // accurate for callers that read it right after this returns.
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));

    if (!self.eventTap) {
        NSLog(@"[Koe] CGEventTap unavailable (ok, NSEvent monitors active)");
    }
}

- (void)stopTapThread {
    if (!self.tapThread) return;
    // Disable first so the tap stops gating the session event stream
    // immediately, then stop the tap thread's run loop and wait for it to
    // finish tearing the tap down on its own thread.
    if (self.eventTap) {
        CGEventTapEnable(self.eventTap, false);
    }
    CFRunLoopRef tapRunLoop = self.tapRunLoop;
    if (tapRunLoop) {
        CFRunLoopStop(tapRunLoop);
    }
    if (self.tapShutdownSemaphore) {
        dispatch_semaphore_wait(self.tapShutdownSemaphore,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    }
    self.tapThread = nil;
    self.tapShutdownSemaphore = nil;
    self.canConsumeGlobalKeyEvents = NO;
}

- (void)updateTapModeIfNeeded {
    if (!self.running) return;
    if (self.tapWantsActive == [self needsEventConsumption]) return;
    [self stopTapThread];
    [self startTapThread];
}

- (void)tapThreadMain:(dispatch_semaphore_t)readySemaphore {
    @autoreleasepool {
        // When consumption is needed, prefer active taps that can swallow
        // handled events so they do not leak into the user's focused app;
        // some systems reject one tap location but allow another, so try
        // both before degrading to listen-only. When nothing needs to be
        // consumed, go straight to listen-only (see tapWantsActive).
        CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged)
                         | CGEventMaskBit(kCGEventKeyDown)
                         | CGEventMaskBit(kCGEventKeyUp);
        struct {
            CGEventTapLocation location;
            CGEventTapOptions options;
            NSString *logMessage;
        } activeAttempts[] = {
            { kCGSessionEventTap, kCGEventTapOptionDefault, @"[Koe] CGEventTap active on session stream (event suppression enabled)" },
            { kCGHIDEventTap, kCGEventTapOptionDefault, @"[Koe] CGEventTap active on HID stream (event suppression enabled)" },
            { kCGSessionEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap active in listen-only fallback mode on session stream" },
            { kCGHIDEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap active in listen-only fallback mode on HID stream" },
        }, listenAttempts[] = {
            { kCGSessionEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap listening on session stream (no event consumption needed)" },
            { kCGHIDEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap listening on HID stream (no event consumption needed)" },
        };
        BOOL wantActive = self.tapWantsActive;
        __typeof__(activeAttempts[0]) *attempts = wantActive ? activeAttempts : listenAttempts;
        NSUInteger attemptCount = wantActive
            ? sizeof(activeAttempts) / sizeof(activeAttempts[0])
            : sizeof(listenAttempts) / sizeof(listenAttempts[0]);

        self.canConsumeGlobalKeyEvents = NO;
        for (NSUInteger i = 0; i < attemptCount; i++) {
            self.eventTap = CGEventTapCreate(attempts[i].location,
                                             kCGHeadInsertEventTap,
                                             attempts[i].options,
                                             mask,
                                             hotkeyEventCallback,
                                             (__bridge void *)self);
            if (!self.eventTap) {
                continue;
            }

            self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), self.runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(self.eventTap, true);
            self.canConsumeGlobalKeyEvents = (attempts[i].options == kCGEventTapOptionDefault);
            NSLog(@"%@", attempts[i].logMessage);
            break;
        }

        self.tapRunLoop = CFRunLoopGetCurrent();
        dispatch_semaphore_signal(readySemaphore);

        if (self.runLoopSource) {
            CFRunLoopRun(); // exits via CFRunLoopStop from -stop
        }

        // Tear the tap down on the thread that owns it, so the callback can
        // never race the release.
        if (self.eventTap) {
            CGEventTapEnable(self.eventTap, false);
        }
        if (self.runLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), self.runLoopSource, kCFRunLoopCommonModes);
            CFRelease(self.runLoopSource);
            self.runLoopSource = NULL;
        }
        if (self.eventTap) {
            CFRelease(self.eventTap);
            self.eventTap = NULL;
        }
        self.tapRunLoop = NULL;
        dispatch_semaphore_signal(self.tapShutdownSemaphore);
    }
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (suspended && [self hasUnconfirmedPreCapture]) {
        [self cancelHoldTimer];
        [self cancelDoubleTapTimer];
        self.triggerDown = NO;
        self.state = SPHotkeyStateIdle;
        [self.delegate hotkeyMonitorDidCancelTrigger];
    } else if (suspended &&
               (self.state == SPHotkeyStateDoubleTapFirstDown ||
                self.state == SPHotkeyStateDoubleTapWaiting)) {
        [self cancelDoubleTapTimer];
        self.triggerDown = NO;
        self.state = SPHotkeyStateIdle;
    } else if (!suspended) {
        // Reset state machine on unsuspend — key events were missed while
        // suspended, so triggerDown and state may be out of sync with reality.
        // Without this, stale state can cause phantom key-up/down firings.
        [self cancelHoldTimer];
        [self cancelDoubleTapTimer];
        [self cancelPendingModifierRelease];
        self.triggerDown = NO;
        self.state = SPHotkeyStateIdle;
    }
}

- (BOOL)isTargetKeyCode:(NSInteger)keyCode {
    return keyCode == self.targetKeyCode || (self.altKeyCode != 0 && keyCode == self.altKeyCode);
}

- (BOOL)isModifierOnlyMatchKind:(uint8_t)matchKind {
    return matchKind == SPHotkeyMatchKindModifierOnly;
}

- (BOOL)keyModifiers:(NSUInteger)flags matchRequiredModifiers:(NSUInteger)requiredFlags {
    NSUInteger relevantFlags = flags & SPHotkeyRelevantModifierMask;
    return relevantFlags == requiredFlags;
}

- (BOOL)isRecordingState {
    return self.state == SPHotkeyStateRecordingHold || self.state == SPHotkeyStateRecordingToggle;
}

- (BOOL)hasUnconfirmedPreCapture {
    return self.state == SPHotkeyStatePending ||
           self.state == SPHotkeyStateDoubleTapSecondDown;
}

@synthesize numberKeyHandler = _numberKeyHandler;

- (BOOL (^)(NSInteger))numberKeyHandler {
    @synchronized (self) {
        return _numberKeyHandler;
    }
}

- (void)setNumberKeyHandler:(BOOL (^)(NSInteger))handler {
    BOOL hadHandler;
    BOOL hasHandler;
    @synchronized (self) {
        hadHandler = (_numberKeyHandler != nil);
        _numberKeyHandler = [handler copy];
        hasHandler = (_numberKeyHandler != nil);
    }
    // Number-key capture is the only reason a modifier-only trigger needs an
    // ACTIVE tap. Upgrade while the template selector is visible; downgrade
    // back to listen-only as soon as it goes away.
    if (hadHandler != hasHandler) {
        [self updateTapModeIfNeeded];
    }
}

- (BOOL)handleNumberKeyWithKeyCode:(NSInteger)keyCode {
    if (!self.numberKeyHandler) return NO;

    NSInteger number = numberForKeyCode(keyCode);
    if (number <= 0) return NO;

    // The handler consults overlay UI state, so it must run on the main
    // thread, and the tap callback needs the consume decision synchronously.
    // Wait with a short timeout: if the main thread is too busy to answer,
    // let the key pass through rather than stall the session event stream
    // (a stalled tap swallows events — the root cause of issues #57/#65).
    BOOL (^handler)(NSInteger) = self.numberKeyHandler;
    __block BOOL handled = NO;
    if ([NSThread isMainThread]) {
        handled = handler(number);
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL mainResult = NO;
        SPPerformOnMainRunLoop(^{
            mainResult = handler(number);
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(100 * NSEC_PER_MSEC))) == 0) {
            handled = mainResult;
        }
    }

    if (handled) {
        @synchronized (self) {
            [self.suppressedNumberKeyCodes addObject:@(keyCode)];
        }
    }
    return handled;
}

@synthesize enterKeyHandler = _enterKeyHandler;

- (BOOL (^)(void))enterKeyHandler {
    @synchronized (self) {
        return _enterKeyHandler;
    }
}

- (void)setEnterKeyHandler:(BOOL (^)(void))handler {
    BOOL hadHandler;
    BOOL hasHandler;
    @synchronized (self) {
        hadHandler = (_enterKeyHandler != nil);
        _enterKeyHandler = [handler copy];
        hasHandler = (_enterKeyHandler != nil);
    }
    // Like number-key capture, the Enter accept needs an ACTIVE tap on
    // modifier-only triggers. Upgrade while the raw-ASR fallback is armed;
    // downgrade back to listen-only as soon as it goes away.
    if (hadHandler != hasHandler) {
        [self updateTapModeIfNeeded];
    }
}

- (BOOL)handleEnterKeyWithKeyCode:(NSInteger)keyCode {
    if (!isReturnKeyCode(keyCode)) return NO;
    if (!self.enterKeyHandler) return NO;

    // Same main-thread contract and timeout rationale as
    // handleNumberKeyWithKeyCode above.
    BOOL (^handler)(void) = self.enterKeyHandler;
    __block BOOL handled = NO;
    if ([NSThread isMainThread]) {
        handled = handler();
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL mainResult = NO;
        SPPerformOnMainRunLoop(^{
            mainResult = handler();
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(100 * NSEC_PER_MSEC))) == 0) {
            handled = mainResult;
        }
    }

    if (handled) {
        @synchronized (self) {
            [self.suppressedNumberKeyCodes addObject:@(keyCode)];
        }
    }
    return handled;
}

- (BOOL)consumeSuppressedNumberKeyForKeyCode:(NSInteger)keyCode isKeyUp:(BOOL)isKeyUp {
    NSNumber *keyCodeNumber = @(keyCode);
    @synchronized (self) {
        if (![self.suppressedNumberKeyCodes containsObject:keyCodeNumber]) {
            return NO;
        }
        if (isKeyUp) {
            [self.suppressedNumberKeyCodes removeObject:keyCodeNumber];
        }
    }
    return YES;
}

- (BOOL)isSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        return [self.suppressedHotkeyKeyCodes containsObject:keyCodeNumber];
    }
}

- (void)addSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        [self.suppressedHotkeyKeyCodes addObject:keyCodeNumber];
    }
}

- (BOOL)removeSuppressedHotkeyKeyCodeIfPresent:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        if (![self.suppressedHotkeyKeyCodes containsObject:keyCodeNumber]) {
            return NO;
        }
        [self.suppressedHotkeyKeyCodes removeObject:keyCodeNumber];
        return YES;
    }
}

- (NSUInteger)currentModifierFlags {
    return [NSEvent modifierFlags] & SPHotkeyRelevantModifierMask;
}

- (BOOL)handleNSEvent:(NSEvent *)event {
    if (!self.running || self.suspended) return NO;

    // The NSEvent monitors exist only as a fallback for when the CGEventTap
    // is unavailable (no Input Monitoring permission) or disabled. While the
    // tap is live it already sees every one of these events — earlier, on
    // its own thread. Also acting on the monitor copy would double-process
    // each physical keystroke: the tap thread outruns NSEvent delivery, so
    // a fast trigger tap arrives as down/up (tap) followed by down/up
    // (monitor) and the triggerDown dedup reads the late copies as a second
    // tap — starting a session and instantly ending it.
    CFMachPortRef tap = self.eventTap;
    if (tap && CGEventTapIsEnabled(tap)) return NO;

    if (event.type == NSEventTypeFlagsChanged) {
        NSUInteger flags = event.modifierFlags;
        NSInteger keyCode = event.keyCode;
        NSLog(@"[Koe] NSEvent FlagsChanged: keyCode=%ld flags=0x%lx", (long)keyCode, (unsigned long)flags);

        if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
            if (![self isTargetKeyCode:keyCode]) {
                if (self.triggerDown && (flags & self.targetModifierFlag) != 0) {
                    [self cancelDoubleTapCandidateForInterveningInput];
                }
                return NO;
            }
            BOOL keyNow = (flags & self.targetModifierFlag) != 0;
            if (keyNow != self.triggerDown) {
                self.triggerDown = keyNow;
                if (keyNow) {
                    [self handleTriggerDown];
                } else if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                    [self scheduleModifierRelease];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    } else if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        NSInteger keyCode = event.keyCode;
        if (event.type == NSEventTypeKeyDown && ![self isTargetKeyCode:keyCode]) {
            [self cancelDoubleTapCandidateForInterveningInput];
        }
        if ([self consumeSuppressedNumberKeyForKeyCode:keyCode isKeyUp:(event.type == NSEventTypeKeyUp)]) {
            return YES;
        }
        if ([event isARepeat]) return NO;
        NSUInteger flags = event.modifierFlags;

        if (event.type == NSEventTypeKeyDown && [self handleNumberKeyWithKeyCode:keyCode]) {
            return YES;
        }

        // Some macOS versions send modifier keys as keyDown/keyUp events. Keep
        // a direct keyDown/keyUp fallback for modifier-only triggers like Fn.
        BOOL shouldHandleTriggerKeyEvent = NO;
        if ([self isTargetKeyCode:keyCode]) {
            if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                shouldHandleTriggerKeyEvent = YES;
            } else if ([self keyModifiers:flags matchRequiredModifiers:self.targetModifierFlag]) {
                shouldHandleTriggerKeyEvent = YES;
            }
        }

        if (shouldHandleTriggerKeyEvent) {
            BOOL isDown;
            if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                isDown = (flags & self.targetModifierFlag) != 0;
            } else {
                isDown = (event.type == NSEventTypeKeyDown);
            }
            NSLog(@"[Koe] NSEvent Key%@: keyCode=%ld", isDown ? @"Down" : @"Up", (long)keyCode);
            if (isDown != self.triggerDown) {
                self.triggerDown = isDown;
                if (isDown) {
                    [self handleTriggerDown];
                } else if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                    [self scheduleModifierRelease];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    }
    return NO;
}

- (void)stop {
    // Set running=NO first so that any in-flight callbacks or dispatched
    // blocks see the flag before we tear down the monitors.
    self.running = NO;

    if (self.globalMonitorRef) {
        [NSEvent removeMonitor:self.globalMonitorRef];
        self.globalMonitorRef = nil;
    }
    if (self.localMonitorRef) {
        [NSEvent removeMonitor:self.localMonitorRef];
        self.localMonitorRef = nil;
    }
    [self stopTapThread];

    BOOL hadPendingTrigger = [self hasUnconfirmedPreCapture];
    [self cancelHoldTimer];
    [self cancelDoubleTapTimer];
    [self cancelPendingModifierRelease];
    self.state = SPHotkeyStateIdle;
    self.canConsumeGlobalKeyEvents = NO;
    @synchronized (self) {
        [self.suppressedNumberKeyCodes removeAllObjects];
        [self.suppressedHotkeyKeyCodes removeAllObjects];
    }
    if (hadPendingTrigger) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
    NSLog(@"[Koe] Hotkey monitor stopped");
}

- (void)handleFlagsChangedEvent:(CGEventRef)event {
    CGEventFlags flags = CGEventGetFlags(event);
    NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    // Log every flags-changed event for debugging
    NSLog(@"[Koe] FlagsChanged: keyCode=%ld flags=0x%llx", (long)keyCode, (unsigned long long)flags);

    // Target key detection:
    // 1. Check if keyCode matches the configured trigger key
    // 2. Check modifier flag bit for key state
    BOOL triggerNow;
    if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
        triggerNow = (flags & self.targetModifierFlag) != 0;
        BOOL isReleaseFallback = self.triggerDown && !triggerNow;
        if (![self isTargetKeyCode:keyCode] && !isReleaseFallback) {
            if (self.triggerDown && triggerNow) {
                SPPerformOnMainRunLoop(^{
                    [self cancelDoubleTapCandidateForInterveningInput];
                });
            }
            return;
        }
    } else {
        return;
    }

    // Dedup and mutate triggerDown ON THE MAIN THREAD (see the keyDown path
    // in hotkeyEventCallback for why): the NSEvent monitor delivers the same
    // physical event on the main thread, and deciding edges against a
    // triggerDown that the tap thread already flipped lets a fast tap be
    // processed twice — starting a session and instantly ending it.
    if (triggerNow) {
        SPPerformOnMainRunLoop(^{
            if (self.triggerDown) return;
            self.triggerDown = YES;
            [self handleTriggerDown];
        });
    } else {
        SPPerformOnMainRunLoop(^{
            if (!self.triggerDown) return;
            self.triggerDown = NO;
            [self scheduleModifierRelease];
        });
    }
}

- (void)cancelPendingModifierRelease {
    if (self.pendingModifierReleaseBlock) {
        dispatch_block_cancel(self.pendingModifierReleaseBlock);
        self.pendingModifierReleaseBlock = nil;
    }
}

- (void)scheduleModifierRelease {
    [self cancelPendingModifierRelease];

    // An unconfirmed gesture must resolve key-up immediately. In particular,
    // delaying double-tap releases by the modifier debounce window would make
    // it impossible for the second press to arrive within the gesture window.
    if (self.state == SPHotkeyStatePending ||
        self.state == SPHotkeyStateDoubleTapFirstDown ||
        self.state == SPHotkeyStateDoubleTapSecondDown ||
        self.state == SPHotkeyStateDoubleTapStopPending) {
        self.triggerDown = NO;
        [self handleTriggerUp];
        return;
    }

    // The debounce timer fires on a global queue and hops back to the main
    // thread in common modes. dispatch_after onto the main queue would not
    // fire while a modal loop runs (Sparkle update prompt, NSAlert) — the
    // release would freeze there while trigger-down events keep arriving,
    // wedging the state machine.
    __block dispatch_block_t scheduled = nil;
    scheduled = dispatch_block_create(0, ^{
        SPPerformOnMainRunLoop(^{
            // Superseded or cancelled while we hopped threads.
            if (self.pendingModifierReleaseBlock != scheduled) return;
            self.pendingModifierReleaseBlock = nil;
            if (([self currentModifierFlags] & self.targetModifierFlag) != 0) {
                self.triggerDown = YES;
                return;
            }
            self.triggerDown = NO;
            [self handleTriggerUp];
        });
    });
    self.pendingModifierReleaseBlock = scheduled;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SPModifierOnlyReleaseDebounceSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                   scheduled);
}

- (void)handleTriggerDown {
    if (!self.running) return;
    [self cancelPendingModifierRelease];
    NSLog(@"[Koe] Trigger DOWN (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStateIdle:
            if (self.triggerMode == SPHotkeyTriggerModeDoubleTap) {
                self.state = SPHotkeyStateDoubleTapFirstDown;
                [self startDoubleTapTimer];
            } else {
                self.state = SPHotkeyStatePending;
                [self startHoldTimer];
                [self.delegate hotkeyMonitorDidBeginTrigger];
            }
            break;

        case SPHotkeyStateDoubleTapWaiting:
            [self cancelDoubleTapTimer];
            self.state = SPHotkeyStateDoubleTapSecondDown;
            [self.delegate hotkeyMonitorDidBeginTrigger];
            break;

        case SPHotkeyStateRecordingToggle:
            if (self.triggerMode == SPHotkeyTriggerModeDoubleTap) {
                self.state = SPHotkeyStateDoubleTapStopPending;
            } else {
                self.state = SPHotkeyStateConsumeKeyUp;
                [self.delegate hotkeyMonitorDidDetectTapEnd];
            }
            break;

        default:
            break;
    }
}

- (void)handleTriggerUp {
    if (!self.running) return;
    NSLog(@"[Koe] Trigger UP (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStatePending:
            [self cancelHoldTimer];
            if (self.triggerMode == SPHotkeyTriggerModeToggle) {
                // Toggle mode: short press starts recording
                self.state = SPHotkeyStateRecordingToggle;
                [self.delegate hotkeyMonitorDidDetectTapStart];
            } else {
                // Hold mode: short press is ignored
                self.state = SPHotkeyStateIdle;
                [self.delegate hotkeyMonitorDidCancelTrigger];
            }
            break;

        case SPHotkeyStateDoubleTapFirstDown:
            self.state = SPHotkeyStateDoubleTapWaiting;
            break;

        case SPHotkeyStateDoubleTapSecondDown:
            self.state = SPHotkeyStateRecordingToggle;
            [self.delegate hotkeyMonitorDidDetectTapStart];
            break;

        case SPHotkeyStateRecordingHold:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectHoldEnd];
            break;

        case SPHotkeyStateDoubleTapStopPending:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectTapEnd];
            break;

        case SPHotkeyStateConsumeKeyUp:
            self.state = SPHotkeyStateIdle;
            break;

        default:
            break;
    }
}

- (void)startHoldTimer {
    [self cancelHoldTimer];
    __weak typeof(self) weakSelf = self;
    // Common modes so hold classification keeps working during modal or
    // menu-tracking run loops (default-mode timers freeze there).
    NSTimer *timer = [NSTimer timerWithTimeInterval:(self.holdThresholdMs / 1000.0)
                                            repeats:NO
                                              block:^(NSTimer *t) {
        [weakSelf holdTimerFired];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.holdTimer = timer;
}

- (void)cancelHoldTimer {
    [self.holdTimer invalidate];
    self.holdTimer = nil;
}

- (void)startDoubleTapTimer {
    [self cancelDoubleTapTimer];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:(self.doubleTapThresholdMs / 1000.0)
                                            repeats:NO
                                              block:^(NSTimer *t) {
        [weakSelf doubleTapTimerFired];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.doubleTapTimer = timer;
}

- (void)cancelDoubleTapTimer {
    [self.doubleTapTimer invalidate];
    self.doubleTapTimer = nil;
}

- (void)doubleTapTimerFired {
    self.doubleTapTimer = nil;
    if (self.state == SPHotkeyStateDoubleTapFirstDown ||
        self.state == SPHotkeyStateDoubleTapWaiting) {
        self.state = SPHotkeyStateIdle;
    }
}

- (void)cancelDoubleTapCandidateForInterveningInput {
    if (self.triggerMode != SPHotkeyTriggerModeDoubleTap) return;

    BOOL hadPreCapture = self.state == SPHotkeyStateDoubleTapSecondDown;
    BOOL hadStopCandidate = self.state == SPHotkeyStateDoubleTapStopPending;
    if (self.state != SPHotkeyStateDoubleTapFirstDown &&
        self.state != SPHotkeyStateDoubleTapWaiting &&
        !hadPreCapture &&
        !hadStopCandidate) {
        return;
    }

    [self cancelDoubleTapTimer];
    if (hadStopCandidate) {
        self.state = SPHotkeyStateRecordingToggle;
        return;
    }

    self.state = SPHotkeyStateIdle;
    if (hadPreCapture) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
}

- (void)holdTimerFired {
    if (self.state != SPHotkeyStatePending) return;
    if (self.triggerMode == SPHotkeyTriggerModeToggle) return;

    self.state = SPHotkeyStateRecordingHold;
    [self.delegate hotkeyMonitorDidDetectHoldStart];
}

- (void)resetToIdle {
    BOOL hadPendingTrigger = [self hasUnconfirmedPreCapture];
    [self cancelHoldTimer];
    [self cancelDoubleTapTimer];
    [self cancelPendingModifierRelease];
    self.triggerDown = NO;
    self.state = SPHotkeyStateIdle;
    @synchronized (self) {
        [self.suppressedNumberKeyCodes removeAllObjects];
        [self.suppressedHotkeyKeyCodes removeAllObjects];
    }
    if (hadPendingTrigger) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
}

@end

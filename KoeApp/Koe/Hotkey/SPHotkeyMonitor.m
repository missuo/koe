#import "SPHotkeyMonitor.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SPHotkeyState) {
    SPHotkeyStateIdle,
    SPHotkeyStatePending,        // Trigger key pressed, waiting to determine tap vs hold
    SPHotkeyStateRecordingHold,  // Confirmed hold, recording
    SPHotkeyStateRecordingToggle, // Confirmed tap, free-hands recording
    SPHotkeyStateConsumeKeyUp,   // Waiting to consume keyUp after toggle-stop
};

@interface SPHotkeyMonitor ()

@property (nonatomic, weak) id<SPHotkeyMonitorDelegate> delegate;
@property (nonatomic, assign) SPHotkeyState state;
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, assign) BOOL triggerDown;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;
@property (nonatomic, strong) id globalMonitorRef;
@property (nonatomic, strong) id localMonitorRef;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedNumberKeyCodes;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedHotkeyKeyCodes;

- (void)handleFlagsChangedEvent:(CGEventRef)event;
- (BOOL)isTargetKeyCode:(NSInteger)keyCode;
- (BOOL)isModifierOnlyMatchKind:(uint8_t)matchKind;
- (BOOL)keyModifiers:(NSUInteger)flags matchRequiredModifiers:(NSUInteger)requiredFlags;
- (BOOL)isRecordingState;
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

static const NSUInteger SPHotkeyRelevantModifierMask =
    NSEventModifierFlagCommand |
    NSEventModifierFlagOption |
    NSEventModifierFlagControl |
    NSEventModifierFlagShift |
    NSEventModifierFlagFunction;

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
        BOOL suppressedTriggerKey = [monitor.suppressedHotkeyKeyCodes containsObject:keyCodeNumber];

        if (type == kCGEventKeyUp && [monitor.suppressedNumberKeyCodes containsObject:keyCodeNumber]) {
            [monitor.suppressedNumberKeyCodes removeObject:keyCodeNumber];
            return NULL;
        }

        if (isRepeat) {
            return event;
        }

        // Forward number keys 1-9 if handler is set.
        // When handled, suppress both keyDown and keyUp so the typed digit
        // does not leak into the user's target app.
        if (type == kCGEventKeyDown && monitor.numberKeyHandler) {
            NSInteger number = numberForKeyCode(keyCode);
            if (number > 0) {
                BOOL (^handler)(NSInteger) = monitor.numberKeyHandler;
                __block BOOL handled = NO;
                if ([NSThread isMainThread]) {
                    handled = handler(number);
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        handled = handler(number);
                    });
                }
                if (handled) {
                    [monitor.suppressedNumberKeyCodes addObject:keyCodeNumber];
                    return NULL;
                }
            }
        }

        if (![monitor isModifierOnlyMatchKind:monitor.targetMatchKind] &&
            [monitor isTargetKeyCode:keyCode] &&
            ([monitor keyModifiers:flags matchRequiredModifiers:monitor.targetModifierFlag] ||
             (type == kCGEventKeyUp && suppressedTriggerKey))) {
            CGEventFlags flags = CGEventGetFlags(event);
            NSLog(@"[Koe] Key event: type=%d keyCode=%ld flags=0x%llx",
                  type, (long)keyCode, (unsigned long long)flags);
            BOOL isDown = (type == kCGEventKeyDown);
            if (isDown != monitor.triggerDown) {
                monitor.triggerDown = isDown;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (isDown) {
                        [monitor handleTriggerDown];
                    } else {
                        [monitor handleTriggerUp];
                    }
                });
            }
            if (isDown) {
                [monitor.suppressedHotkeyKeyCodes addObject:keyCodeNumber];
                return NULL;
            }
            if (suppressedTriggerKey) {
                [monitor.suppressedHotkeyKeyCodes removeObject:keyCodeNumber];
                return NULL;
            }
        }

        if (type == kCGEventKeyUp && [monitor.suppressedHotkeyKeyCodes containsObject:keyCodeNumber]) {
            [monitor.suppressedHotkeyKeyCodes removeObject:keyCodeNumber];
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
        _state = SPHotkeyStateIdle;
        _triggerDown = NO;
        _targetKeyCode = 63;       // kVK_Function (Fn)
        _altKeyCode = 179;         // Globe key on newer keyboards
        _targetModifierFlag = 0x00800000; // NX_SECONDARYFNMASK
        _targetMatchKind = SPHotkeyMatchKindModifierOnly;
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
        [weakSelf handleNSEvent:event];
        return event;
    }];

    NSLog(@"[Koe] Hotkey monitor started via NSEvent monitors (trigger=%ld/%ld flag=0x%lx kind=%u threshold=%.0fms)",
          (long)self.targetKeyCode,
          (long)self.altKeyCode,
          (unsigned long)self.targetModifierFlag,
          self.targetMatchKind,
          self.holdThresholdMs);

    // Also try CGEventTap as additional source.
    // Prefer active taps that can swallow handled number shortcuts so they do
    // not leak into the user's focused app. Some systems reject one tap
    // location but allow another, so try both before degrading to listen-only.
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged)
                     | CGEventMaskBit(kCGEventKeyDown)
                     | CGEventMaskBit(kCGEventKeyUp);
    struct {
        CGEventTapLocation location;
        CGEventTapOptions options;
        NSString *logMessage;
    } attempts[] = {
        { kCGSessionEventTap, kCGEventTapOptionDefault, @"[Koe] CGEventTap active on session stream (event suppression enabled)" },
        { kCGHIDEventTap, kCGEventTapOptionDefault, @"[Koe] CGEventTap active on HID stream (event suppression enabled)" },
        { kCGSessionEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap active in listen-only fallback mode on session stream" },
        { kCGHIDEventTap, kCGEventTapOptionListenOnly, @"[Koe] CGEventTap active in listen-only fallback mode on HID stream" },
    };

    for (NSUInteger i = 0; i < sizeof(attempts) / sizeof(attempts[0]); i++) {
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
        CFRunLoopAddSource(CFRunLoopGetMain(), self.runLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(self.eventTap, true);
        NSLog(@"%@", attempts[i].logMessage);
        break;
    }

    if (!self.eventTap) {
        NSLog(@"[Koe] CGEventTap unavailable (ok, NSEvent monitors active)");
    }
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (!suspended) {
        // Reset state machine on unsuspend — key events were missed while
        // suspended, so triggerDown and state may be out of sync with reality.
        // Without this, stale state can cause phantom key-up/down firings.
        [self cancelHoldTimer];
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
    return (flags & SPHotkeyRelevantModifierMask) == requiredFlags;
}

- (BOOL)isRecordingState {
    return self.state == SPHotkeyStateRecordingHold || self.state == SPHotkeyStateRecordingToggle;
}

- (void)handleNSEvent:(NSEvent *)event {
    if (!self.running || self.suspended) return;

    if (event.type == NSEventTypeFlagsChanged) {
        NSUInteger flags = event.modifierFlags;
        NSInteger keyCode = event.keyCode;
        NSLog(@"[Koe] NSEvent FlagsChanged: keyCode=%ld flags=0x%lx", (long)keyCode, (unsigned long)flags);

        if ([self isModifierOnlyMatchKind:self.targetMatchKind] && [self isTargetKeyCode:keyCode]) {
            BOOL keyNow = (flags & self.targetModifierFlag) != 0;
            if (keyNow != self.triggerDown) {
                self.triggerDown = keyNow;
                if (keyNow) {
                    [self handleTriggerDown];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    } else if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        if ([event isARepeat]) return;
        NSInteger keyCode = event.keyCode;
        NSUInteger flags = event.modifierFlags;

        // Some macOS versions send modifier keys as keyDown/keyUp events. For
        // keyDown-matched shortcuts, only trigger when the exact modifier set matches.
        if (![self isModifierOnlyMatchKind:self.targetMatchKind] &&
            [self isTargetKeyCode:keyCode] &&
            [self keyModifiers:flags matchRequiredModifiers:self.targetModifierFlag]) {
            BOOL isDown = (event.type == NSEventTypeKeyDown);
            NSLog(@"[Koe] NSEvent Key%@: keyCode=%ld", isDown ? @"Down" : @"Up", (long)keyCode);
            if (isDown != self.triggerDown) {
                self.triggerDown = isDown;
                if (isDown) {
                    [self handleTriggerDown];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    }
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
    if (self.eventTap) {
        CGEventTapEnable(self.eventTap, false);
        if (self.runLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), self.runLoopSource, kCFRunLoopCommonModes);
            CFRelease(self.runLoopSource);
            self.runLoopSource = NULL;
        }
        CFRelease(self.eventTap);
        self.eventTap = NULL;
    }

    [self cancelHoldTimer];
    self.state = SPHotkeyStateIdle;
    [self.suppressedNumberKeyCodes removeAllObjects];
    [self.suppressedHotkeyKeyCodes removeAllObjects];
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
    if ([self isModifierOnlyMatchKind:self.targetMatchKind] && [self isTargetKeyCode:keyCode]) {
        triggerNow = (flags & self.targetModifierFlag) != 0;
    } else {
        return;
    }

    if (triggerNow == self.triggerDown) return;

    self.triggerDown = triggerNow;

    if (triggerNow) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleTriggerDown];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleTriggerUp];
        });
    }
}

- (void)handleTriggerDown {
    if (!self.running) return;
    NSLog(@"[Koe] Trigger DOWN (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStateIdle:
            self.state = SPHotkeyStatePending;
            [self startHoldTimer];
            break;

        case SPHotkeyStateRecordingToggle:
            self.state = SPHotkeyStateConsumeKeyUp;
            [self.delegate hotkeyMonitorDidDetectTapEnd];
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
            if (self.triggerMode == 1) {
                // Toggle mode: short press starts recording
                self.state = SPHotkeyStateRecordingToggle;
                [self.delegate hotkeyMonitorDidDetectTapStart];
            } else {
                // Hold mode: short press is ignored
                self.state = SPHotkeyStateIdle;
            }
            break;

        case SPHotkeyStateRecordingHold:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectHoldEnd];
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
    self.holdTimer = [NSTimer scheduledTimerWithTimeInterval:(self.holdThresholdMs / 1000.0)
                                                    repeats:NO
                                                      block:^(NSTimer *timer) {
        [weakSelf holdTimerFired];
    }];
}

- (void)cancelHoldTimer {
    [self.holdTimer invalidate];
    self.holdTimer = nil;
}

- (void)holdTimerFired {
    if (self.state == SPHotkeyStatePending) {
        self.state = SPHotkeyStateRecordingHold;
        [self.delegate hotkeyMonitorDidDetectHoldStart];
    }
}

- (void)resetToIdle {
    [self cancelHoldTimer];
    self.triggerDown = NO;
    self.state = SPHotkeyStateIdle;
    [self.suppressedNumberKeyCodes removeAllObjects];
}

@end

#import "SPHotkeyMonitor.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SPHotkeyState) {
    SPHotkeyStateIdle,
    SPHotkeyStatePending,        // Fn pressed, waiting to determine tap vs hold
    SPHotkeyStateRecordingHold,  // Confirmed hold, recording
    SPHotkeyStateRecordingToggle, // Confirmed tap, free-hands recording
    SPHotkeyStateConsumeKeyUp,   // Waiting to consume keyUp after toggle-stop
};

@interface SPHotkeyMonitor ()

@property (nonatomic, weak) id<SPHotkeyMonitorDelegate> delegate;
@property (nonatomic, assign) SPHotkeyState state;
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, assign) BOOL fnDown;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;
@property (nonatomic, strong) id globalMonitorRef;
@property (nonatomic, strong) id localMonitorRef;

- (void)handleFlagsChangedEvent:(CGEventRef)event;
- (BOOL)isTargetKeyCode:(NSInteger)keyCode;

@end

// C callback for CGEventTap
static CGEventRef hotkeyEventCallback(CGEventTapProxy proxy,
                                       CGEventType type,
                                       CGEventRef event,
                                       void *userInfo) {
    SPHotkeyMonitor *monitor = (__bridge SPHotkeyMonitor *)userInfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (monitor.eventTap) {
            CGEventTapEnable(monitor.eventTap, true);
        }
        return event;
    }

    if (monitor.suspended) return event;

    if (type == kCGEventFlagsChanged) {
        [monitor handleFlagsChangedEvent:event];
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if ([monitor isTargetKeyCode:keyCode]) {
            CGEventFlags flags = CGEventGetFlags(event);
            NSLog(@"[Koe] Key event: type=%d keyCode=%ld flags=0x%llx",
                  type, (long)keyCode, (unsigned long long)flags);
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
        _fnDown = NO;
        _targetKeyCode = 63;       // kVK_Function (Fn)
        _altKeyCode = 179;         // Globe key on newer keyboards
        _targetModifierFlag = 0x800000; // NSEventModifierFlagFunction
    }
    return self;
}

- (void)start {
    if (self.globalMonitorRef) return;

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

    NSLog(@"[Koe] Hotkey monitor started via NSEvent monitors (keyCode=%ld altKeyCode=%ld modifierFlag=0x%lx threshold=%.0fms)",
          (long)self.targetKeyCode, (long)self.altKeyCode, (unsigned long)self.targetModifierFlag, self.holdThresholdMs);

    // Also try CGEventTap as additional source
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged)
                     | CGEventMaskBit(kCGEventKeyDown)
                     | CGEventMaskBit(kCGEventKeyUp);
    self.eventTap = CGEventTapCreate(kCGHIDEventTap,
                                      kCGHeadInsertEventTap,
                                      kCGEventTapOptionListenOnly,
                                      mask,
                                      hotkeyEventCallback,
                                      (__bridge void *)self);
    if (self.eventTap) {
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), self.runLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(self.eventTap, true);
        NSLog(@"[Koe] CGEventTap also active");
    } else {
        NSLog(@"[Koe] CGEventTap unavailable (ok, NSEvent monitors active)");
    }
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (!suspended) {
        // Reset state machine on unsuspend — key events were missed while
        // suspended, so fnDown and state may be out of sync with reality.
        // Without this, stale state can cause phantom key-up/down firings.
        [self cancelHoldTimer];
        self.fnDown = NO;
        self.state = SPHotkeyStateIdle;
    }
}

- (BOOL)isTargetKeyCode:(NSInteger)keyCode {
    return keyCode == self.targetKeyCode || (self.altKeyCode != 0 && keyCode == self.altKeyCode);
}

- (void)handleNSEvent:(NSEvent *)event {
    if (self.suspended) return;

    if (event.type == NSEventTypeFlagsChanged) {
        NSUInteger flags = event.modifierFlags;
        NSInteger keyCode = event.keyCode;
        NSLog(@"[Koe] NSEvent FlagsChanged: keyCode=%ld flags=0x%lx", (long)keyCode, (unsigned long)flags);

        if ([self isTargetKeyCode:keyCode]) {
            BOOL keyNow = (flags & self.targetModifierFlag) != 0;
            if (keyNow != self.fnDown) {
                self.fnDown = keyNow;
                if (keyNow) {
                    [self handleFnDown];
                } else {
                    [self handleFnUp];
                }
            }
        }
    } else if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        // Some macOS versions send modifier keys as keyDown/keyUp events
        NSInteger keyCode = event.keyCode;
        if ([self isTargetKeyCode:keyCode]) {
            BOOL isDown = (event.type == NSEventTypeKeyDown);
            NSLog(@"[Koe] NSEvent Key%@: keyCode=%ld", isDown ? @"Down" : @"Up", (long)keyCode);
            if (isDown != self.fnDown) {
                self.fnDown = isDown;
                if (isDown) {
                    [self handleFnDown];
                } else {
                    [self handleFnUp];
                }
            }
        }
    }
}

- (void)stop {
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
    BOOL fnNow;
    if ([self isTargetKeyCode:keyCode]) {
        fnNow = (flags & self.targetModifierFlag) != 0;
    } else {
        return;
    }

    if (fnNow == self.fnDown) return;

    self.fnDown = fnNow;

    if (fnNow) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleFnDown];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleFnUp];
        });
    }
}

- (void)handleFnDown {
    NSLog(@"[Koe] Fn DOWN (state=%ld)", (long)self.state);
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

- (void)handleFnUp {
    NSLog(@"[Koe] Fn UP (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStatePending:
            [self cancelHoldTimer];
            self.state = SPHotkeyStateRecordingToggle;
            [self.delegate hotkeyMonitorDidDetectTapStart];
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
    self.fnDown = NO;
    self.state = SPHotkeyStateIdle;
}

@end

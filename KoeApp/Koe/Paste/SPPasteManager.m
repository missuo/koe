#import "SPPasteManager.h"
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

@interface SPPasteManager ()
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation SPPasteManager

// Create an event source with a *private* modifier state so that synthetic
// Cmd+V / Cmd+Z events do not merge with whatever modifier keys the user is
// physically holding at the moment of injection. Using
// kCGEventSourceStateHIDSystemState (the previous behavior) caused injected
// events to pick up real hardware flags — e.g. if the user was still holding
// Control (the LLM-invert modifier) when a paste fired, the posted Cmd+V
// became Control+Cmd+V, and similar bleed turned Cmd+Z into Control+Cmd+Z or
// dropped the Cmd entirely, resulting in random letters typed into the
// target app.
static CGEventSourceRef createPrivateEventSource(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (source) {
        CGEventSourceSetLocalEventsFilterDuringSuppressionState(
            source,
            kCGEventFilterMaskPermitLocalMouseEvents | kCGEventFilterMaskPermitSystemDefinedEvents,
            kCGEventSuppressionStateSuppressionInterval);
    }
    return source;
}

- (void)simulatePasteWithCompletion:(void (^)(void))completion {
    self.cancelled = NO;
    // Small delay after clipboard write to ensure it's ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        [self performPaste];

        // Delay after paste to let the target app process it
        if (completion) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (self.cancelled) return;
                completion();
            });
        }
    });
}

- (void)performPaste {
    if (self.cancelled) return;

    CGEventSourceRef source = createPrivateEventSource();
    if (!source) {
        NSLog(@"[Koe] Failed to create event source for paste");
        return;
    }

    // Key code for 'V' is 9 (kVK_ANSI_V)
    CGEventRef cmdDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_V, true);
    CGEventRef cmdUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_V, false);

    // Set the Command modifier on the synthetic events. Because `source` has
    // a private modifier state, these flags will not merge with real hardware
    // modifiers.
    CGEventSetFlags(cmdDown, kCGEventFlagMaskCommand);
    CGEventSetFlags(cmdUp, kCGEventFlagMaskCommand);

    // Post events
    CGEventPost(kCGHIDEventTap, cmdDown);
    CGEventPost(kCGHIDEventTap, cmdUp);

    CFRelease(cmdDown);
    CFRelease(cmdUp);
    CFRelease(source);

    NSLog(@"[Koe] Cmd+V simulated");
}

- (void)simulateUndoThenPasteWithCompletion:(void (^)(void))completion {
    self.cancelled = NO;
    // First simulate Cmd+Z to undo previous paste
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        [self performUndo];

        // Wait for undo to take effect, then paste new content
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (self.cancelled) return;
            [self performPaste];

            if (completion) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    if (self.cancelled) return;
                    completion();
                });
            }
        });
    });
}

- (void)performUndo {
    if (self.cancelled) return;

    CGEventSourceRef source = createPrivateEventSource();
    if (!source) {
        NSLog(@"[Koe] Failed to create event source for undo");
        return;
    }

    // Key code for 'Z' is 6 (kVK_ANSI_Z)
    CGEventRef cmdDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_Z, true);
    CGEventRef cmdUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_Z, false);

    CGEventSetFlags(cmdDown, kCGEventFlagMaskCommand);
    CGEventSetFlags(cmdUp, kCGEventFlagMaskCommand);

    CGEventPost(kCGHIDEventTap, cmdDown);
    CGEventPost(kCGHIDEventTap, cmdUp);

    CFRelease(cmdDown);
    CFRelease(cmdUp);
    CFRelease(source);

    NSLog(@"[Koe] Cmd+Z simulated");
}

- (void)cancel {
    self.cancelled = YES;
}

@end

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
    // NOTE: `cancelled` is sticky. Once -cancel is called (at quit) it stays
    // YES for the lifetime of this manager, so any subsequent simulate* calls
    // become no-ops. This is intentional: during quit, in-flight Rust
    // callbacks can still land on the main queue after `quitting=YES` is set
    // on the app delegate, and we must never fire a synthetic paste after
    // cancel.
    if (self.cancelled) return;
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
    // Post at the session level — NOT kCGHIDEventTap. HID-level posting
    // re-merges the physical keyboard's current modifier state, which means
    // a private-source event with CMD set can still arrive at a target app
    // as CMD+CONTROL (or with CMD dropped entirely) if the user is holding
    // a modifier when the paste fires. Session-level posting honors the
    // private source's clean flag state.
    CGEventPost(kCGSessionEventTap, cmdDown);
    CGEventPost(kCGSessionEventTap, cmdUp);

    CFRelease(cmdDown);
    CFRelease(cmdUp);
    CFRelease(source);

    NSLog(@"[Koe] Cmd+V simulated");
}

- (void)simulateUndoThenPasteWithCompletion:(void (^)(void))completion {
    if (self.cancelled) return;
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

    // Post at the session level — NOT kCGHIDEventTap. HID-level posting
    // re-merges the physical keyboard's current modifier state, which means
    // a private-source event with CMD set can still arrive at a target app
    // as CMD+CONTROL (or with CMD dropped entirely) if the user is holding
    // a modifier when the paste fires. Session-level posting honors the
    // private source's clean flag state.
    CGEventPost(kCGSessionEventTap, cmdDown);
    CGEventPost(kCGSessionEventTap, cmdUp);

    CFRelease(cmdDown);
    CFRelease(cmdUp);
    CFRelease(source);

    NSLog(@"[Koe] Cmd+Z simulated");
}

- (void)simulateReturnKey {
    if (self.cancelled) return;

    CGEventSourceRef source = createPrivateEventSource();
    if (!source) {
        NSLog(@"[Koe] Failed to create event source for return");
        return;
    }

    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_Return, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_Return, false);

    // A bare Return: clear all modifier flags so the private source cannot
    // carry anything over, and so a user still holding the trigger modifier
    // (e.g. Fn) cannot turn this into a modified keypress.
    CGEventSetFlags(keyDown, 0);
    CGEventSetFlags(keyUp, 0);

    CGEventPost(kCGSessionEventTap, keyDown);
    CGEventPost(kCGSessionEventTap, keyUp);

    CFRelease(keyDown);
    CFRelease(keyUp);
    CFRelease(source);

    NSLog(@"[Koe] Return simulated");
}

- (void)cancel {
    self.cancelled = YES;
}

@end

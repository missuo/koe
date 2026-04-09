#import <Foundation/Foundation.h>

/// Delegate protocol for hotkey events
@protocol SPHotkeyMonitorDelegate <NSObject>
- (void)hotkeyMonitorDidDetectHoldStart;
- (void)hotkeyMonitorDidDetectHoldEnd;
- (void)hotkeyMonitorDidDetectTapStart;
- (void)hotkeyMonitorDidDetectTapEnd;
@end

typedef NS_ENUM(uint8_t, SPHotkeyMatchKind) {
    SPHotkeyMatchKindModifierOnly = 0,
    SPHotkeyMatchKindKeyDown = 1,
};

@interface SPHotkeyMonitor : NSObject

/// Threshold in milliseconds to distinguish tap from hold. Default 180ms.
@property (nonatomic, assign) NSTimeInterval holdThresholdMs;

/// Trigger mode: 0 = hold (short press ignored), 1 = toggle (tap to start/stop).
@property (nonatomic, assign) uint8_t triggerMode;

/// Primary key code to monitor (default: 63 = Fn/Globe)
@property (nonatomic, assign) NSInteger targetKeyCode;

/// Alternative key code to monitor (default: 179 = Globe on newer keyboards), 0 to disable
@property (nonatomic, assign) NSInteger altKeyCode;

/// Modifier flag to check for key state (default: 0x800000 = NSEventModifierFlagFunction)
@property (nonatomic, assign) NSUInteger targetModifierFlag;

/// How the trigger hotkey should be matched.
@property (nonatomic, assign) uint8_t targetMatchKind;

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate;
- (void)start;
- (void)stop;

/// Temporarily suppress hotkey detection (e.g. while a menu is open).
@property (nonatomic, assign) BOOL suspended;

/// Reset the state machine to idle. Call when an external event (e.g. audio error)
/// terminates a recording session outside the normal hotkey flow.
- (void)resetToIdle;

/// Optional block called when a number key (1-9) is pressed.
/// Return YES to consume the key event so it does not continue to the target app.
@property (nonatomic, copy) BOOL (^numberKeyHandler)(NSInteger number);

@end

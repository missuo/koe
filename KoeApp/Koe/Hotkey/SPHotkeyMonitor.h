#import <Foundation/Foundation.h>

/// Delegate protocol for hotkey events
@protocol SPHotkeyMonitorDelegate <NSObject>
- (void)hotkeyMonitorDidDetectHoldStart;
- (void)hotkeyMonitorDidDetectHoldEnd;
- (void)hotkeyMonitorDidDetectTapStart;
- (void)hotkeyMonitorDidDetectTapEnd;
- (void)hotkeyMonitorDidDetectCancel;
@end

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

/// Primary key code for the cancel hotkey.
@property (nonatomic, assign) NSInteger cancelKeyCode;

/// Alternative key code for the cancel hotkey, 0 to disable.
@property (nonatomic, assign) NSInteger cancelAltKeyCode;

/// Modifier flag to check for cancel key state.
@property (nonatomic, assign) NSUInteger cancelModifierFlag;

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate;
- (void)start;
- (void)stop;

/// Temporarily suppress hotkey detection (e.g. while a menu is open).
@property (nonatomic, assign) BOOL suspended;

/// Reset the state machine to idle. Call when an external event (e.g. audio error)
/// terminates a recording session outside the normal hotkey flow.
- (void)resetToIdle;

/// Optional block called on the main thread when a number key (1-9) is pressed.
/// Set to non-nil to enable number key forwarding via the existing CGEventTap.
/// The block receives the number (1-9). Set to nil to disable.
@property (nonatomic, copy) void (^numberKeyHandler)(NSInteger number);

@end

#import <Foundation/Foundation.h>

/// Delegate protocol for hotkey events
@protocol SPHotkeyMonitorDelegate <NSObject>
- (void)hotkeyMonitorDidDetectHoldStart;
- (void)hotkeyMonitorDidDetectHoldEnd;
- (void)hotkeyMonitorDidDetectTapStart;
- (void)hotkeyMonitorDidDetectTapEnd;
@end

@interface SPHotkeyMonitor : NSObject

/// Threshold in milliseconds to distinguish tap from hold. Default 180ms.
@property (nonatomic, assign) NSTimeInterval holdThresholdMs;

/// Primary key code to monitor (default: 63 = Fn/Globe)
@property (nonatomic, assign) NSInteger targetKeyCode;

/// Alternative key code to monitor (default: 179 = Globe on newer keyboards), 0 to disable
@property (nonatomic, assign) NSInteger altKeyCode;

/// Modifier flag to check for key state (default: 0x800000 = NSEventModifierFlagFunction)
@property (nonatomic, assign) NSUInteger targetModifierFlag;

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate;
- (void)start;
- (void)stop;

/// Temporarily suppress hotkey detection (e.g. while a menu is open).
@property (nonatomic, assign) BOOL suspended;

/// Reset the state machine to idle. Call when an external event (e.g. audio error)
/// terminates a recording session outside the normal hotkey flow.
- (void)resetToIdle;

@end

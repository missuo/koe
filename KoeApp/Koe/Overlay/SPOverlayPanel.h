#import <Cocoa/Cocoa.h>

/// Floating status pill displayed at bottom-center of screen, above the Dock.
/// Shows current state (recording, processing, etc.) and auto-hides when idle.
@interface SPOverlayPanel : NSObject

- (instancetype)init;

/// Update displayed state. Same state strings as SPStatusBarManager.
- (void)updateState:(NSString *)state;

/// Update interim ASR text shown during recording.
- (void)updateInterimText:(NSString *)text;

@end

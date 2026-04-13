#import <Foundation/Foundation.h>

@interface SPPasteManager : NSObject

/// Simulate Cmd+V paste via CGEvent injection.
/// The completion block is called after a short delay to allow the paste to take effect.
- (void)simulatePasteWithCompletion:(void (^)(void))completion;

/// Simulate Cmd+Z undo, then Cmd+V paste. Used to replace previously pasted text.
/// The completion block is called after the paste takes effect.
- (void)simulateUndoThenPasteWithCompletion:(void (^)(void))completion;

/// Cancel any scheduled paste/undo blocks. Called on quit so that pending
/// CGEventPost injections cannot leak into the user's target app after the
/// hotkey monitor and event tap have been torn down.
- (void)cancel;

@end

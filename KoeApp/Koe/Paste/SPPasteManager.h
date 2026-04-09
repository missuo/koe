#import <Foundation/Foundation.h>

@interface SPPasteManager : NSObject

/// Simulate Cmd+V paste via CGEvent injection.
/// The completion block is called after a short delay to allow the paste to take effect.
- (void)simulatePasteWithCompletion:(void (^)(void))completion;

/// Simulate Cmd+Z undo, then Cmd+V paste. Used to replace previously pasted text.
/// The completion block is called after the paste takes effect.
- (void)simulateUndoThenPasteWithCompletion:(void (^)(void))completion;

@end

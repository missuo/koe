#import <Foundation/Foundation.h>

@interface SPClipboardManager : NSObject

/// Backup the current clipboard contents.
- (void)backup;

/// Write text to the system clipboard.
- (void)writeText:(NSString *)text;

/// Restore clipboard to the backed-up contents after a delay (ms).
/// Will not restore if the clipboard was modified by the user in the meantime.
- (void)scheduleRestoreAfterDelay:(NSUInteger)delayMs;

/// Cancel any pending delayed restore for the current clipboard write.
- (void)cancelPendingRestore;

@end

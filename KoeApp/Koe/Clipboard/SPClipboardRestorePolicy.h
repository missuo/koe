#import <Foundation/Foundation.h>

@class SPClipboardManager;

/// Fallback restoration delay used only if a paste happens before any session
/// snapshot was captured. The authoritative default and validation live in the
/// Rust config layer (`clipboard.restore_delay_ms`); this value mirrors it.
extern const NSUInteger SPClipboardRestoreFallbackDelayMs;

/// Session-scoped clipboard restoration policy shared by both automatic paste
/// flows (normal final-text and experimental ASR-first). The effective delay
/// is snapshotted once per voice-input session, so a config edit during an
/// active session takes effect on the next session.
@interface SPClipboardRestorePolicy : NSObject

@property (nonatomic, strong) SPClipboardManager *clipboardManager;

/// Capture the effective restoration delay for the session that just began.
- (void)captureSessionRestoreDelayMs:(NSUInteger)delayMs;

/// Schedule clipboard restoration using the current session's snapshot.
/// The single entry point for every automatic paste completion callback;
/// clipboard-only delivery must not call this.
- (void)scheduleRestoreForCurrentSession;

@end

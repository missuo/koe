#import <Foundation/Foundation.h>

/// Guard for the experimental "paste ASR first, correct after LLM" flow.
///
/// After the raw ASR text is pasted, `captureAfterPasteWithRawText:` records
/// the focused accessibility element, the caret position, and the inserted
/// text. When the LLM correction arrives, `replaceWithCorrectedText:` swaps
/// the inserted range in place — but only when it can prove nothing changed
/// in between: same focused element, caret still at the end of the inserted
/// text, and the document still contains the exact raw text at the recorded
/// position. Any mismatch (focus moved, user typed or clicked, app lacks
/// accessibility text support) makes it refuse; it never sends Cmd+Z and
/// never edits text it cannot verify.
@interface SPInstantPasteGuard : NSObject

/// Record post-paste state. Returns YES when the focused element supports
/// verified replacement; NO leaves the guard inactive (correction will fall
/// back to clipboard-only delivery).
- (BOOL)captureAfterPasteWithRawText:(NSString *)rawText;

/// Replace the previously pasted raw text with `correctedText` if — and only
/// if — every safety check passes. Returns YES when the document was updated.
/// The guard deactivates after this call regardless of outcome.
- (BOOL)replaceWithCorrectedText:(NSString *)correctedText;

/// Whether a capture is active (raw text was pasted and verified in place).
@property (nonatomic, readonly) BOOL active;

/// Drop any captured state (session ended, cancelled, or errored).
- (void)reset;

@end

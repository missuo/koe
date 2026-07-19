#import <Foundation/Foundation.h>

@interface SPHistoryStats : NSObject

@property (nonatomic, assign) NSInteger sessionCount;
@property (nonatomic, assign) NSInteger totalDurationMs;
@property (nonatomic, assign) NSInteger totalCharCount;
@property (nonatomic, assign) NSInteger totalWordCount;

@end

@interface SPHistoryManager : NSObject

+ (instancetype)sharedManager;

/// Open a history database at a custom path (used by tests; the shared
/// manager uses ~/.koe/history.db). The parent directory is created if needed.
- (instancetype)initWithDatabasePath:(NSString *)dbPath;

/// Record a completed session.
/// `text` is the final (possibly LLM-corrected) text that was pasted.
/// `asrText` is the raw ASR transcript before LLM correction (nil if unknown).
/// `asrProvider` is the ASR provider name, e.g. "doubaoime" (nil if unknown).
/// `llmApplied` is YES only when LLM correction ran and its output was used.
- (void)recordSessionWithDurationMs:(NSInteger)durationMs
                               text:(NSString *)text
                            asrText:(NSString *)asrText
                        asrProvider:(NSString *)asrProvider
                         llmApplied:(BOOL)llmApplied;

- (SPHistoryStats *)aggregateStats;

@end

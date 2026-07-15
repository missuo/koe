#import "SPClipboardRestorePolicy.h"
#import "SPClipboardManager.h"

const NSUInteger SPClipboardRestoreFallbackDelayMs = 1500;

@interface SPClipboardRestorePolicy ()
@property (nonatomic, assign) NSUInteger sessionRestoreDelayMs;
@end

@implementation SPClipboardRestorePolicy

- (instancetype)init {
    self = [super init];
    if (self) {
        _sessionRestoreDelayMs = SPClipboardRestoreFallbackDelayMs;
    }
    return self;
}

- (void)captureSessionRestoreDelayMs:(NSUInteger)delayMs {
    self.sessionRestoreDelayMs = delayMs;
}

- (void)scheduleRestoreForCurrentSession {
    [self.clipboardManager scheduleRestoreAfterDelay:self.sessionRestoreDelayMs];
}

@end

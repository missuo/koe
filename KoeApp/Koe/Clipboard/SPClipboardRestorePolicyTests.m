#import <XCTest/XCTest.h>
#import "SPClipboardRestorePolicy.h"
#import "SPClipboardManager.h"

/// Test double: records restoration scheduling instead of touching the real
/// pasteboard or dispatch timers, so tests stay deterministic and never
/// overwrite the developer's clipboard.
@interface SPClipboardManagerRestoreRecorder : SPClipboardManager
@property (nonatomic, assign) NSInteger scheduleCount;
@property (nonatomic, assign) NSUInteger lastScheduledDelayMs;
@end

@implementation SPClipboardManagerRestoreRecorder

- (void)scheduleRestoreAfterDelay:(NSUInteger)delayMs {
    self.scheduleCount += 1;
    self.lastScheduledDelayMs = delayMs;
}

@end

@interface SPClipboardRestorePolicyTests : XCTestCase
@property (nonatomic, strong) SPClipboardRestorePolicy *policy;
@property (nonatomic, strong) SPClipboardManagerRestoreRecorder *recorder;
@end

@implementation SPClipboardRestorePolicyTests

- (void)setUp {
    [super setUp];
    self.recorder = [[SPClipboardManagerRestoreRecorder alloc] init];
    self.policy = [[SPClipboardRestorePolicy alloc] init];
    self.policy.clipboardManager = self.recorder;
}

- (void)testScheduleUsesSessionSnapshotValue {
    [self.policy captureSessionRestoreDelayMs:250];
    [self.policy scheduleRestoreForCurrentSession];

    XCTAssertEqual(self.recorder.scheduleCount, 1);
    XCTAssertEqual(self.recorder.lastScheduledDelayMs, (NSUInteger)250);
}

- (void)testScheduleWithoutCaptureUsesFallbackDelay {
    [self.policy scheduleRestoreForCurrentSession];

    XCTAssertEqual(self.recorder.scheduleCount, 1);
    XCTAssertEqual(self.recorder.lastScheduledDelayMs, SPClipboardRestoreFallbackDelayMs);
}

- (void)testFallbackDelayMatchesHistoricalDefault {
    XCTAssertEqual(SPClipboardRestoreFallbackDelayMs, (NSUInteger)1500);
}

- (void)testZeroDelayIsScheduledNotSkipped {
    [self.policy captureSessionRestoreDelayMs:0];
    [self.policy scheduleRestoreForCurrentSession];

    XCTAssertEqual(self.recorder.scheduleCount, 1);
    XCTAssertEqual(self.recorder.lastScheduledDelayMs, (NSUInteger)0);
}

- (void)testNewSessionSnapshotReplacesPreviousOne {
    [self.policy captureSessionRestoreDelayMs:250];
    [self.policy scheduleRestoreForCurrentSession];

    // A consecutive session captures its own policy; its automatic paste
    // must use the new snapshot, not the previous session's.
    [self.policy captureSessionRestoreDelayMs:3000];
    [self.policy scheduleRestoreForCurrentSession];

    XCTAssertEqual(self.recorder.scheduleCount, 2);
    XCTAssertEqual(self.recorder.lastScheduledDelayMs, (NSUInteger)3000);
}

- (void)testNoScheduleHappensWithoutExplicitRequest {
    [self.policy captureSessionRestoreDelayMs:250];

    // Clipboard-only delivery never calls the entry point, so nothing may
    // be scheduled as a side effect of capturing a session policy.
    XCTAssertEqual(self.recorder.scheduleCount, 0);
}

@end

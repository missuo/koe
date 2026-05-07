#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "SPHotkeyMonitor.h"

@interface SPAppDelegateSessionStateTestProxy : NSObject
@property (nonatomic, copy) NSString *sessionState;
@property (nonatomic, assign) BOOL hasPendingConfigReload;
@property (nonatomic, assign) NSInteger reloadCount;
- (void)reloadConfigAndApplyHotkey;
- (void)reloadConfigAndApplyHotkeyIfSafe;
- (void)applyDeferredConfigReloadIfNeeded;
@end

static BOOL sessionStateAllowsConfigReloadForTest(NSString *state) {
    if (state.length == 0) return YES;
    return [state isEqualToString:@"idle"] ||
           [state isEqualToString:@"completed"] ||
           [state isEqualToString:@"failed"] ||
           [state isEqualToString:@"error"];
}

@implementation SPAppDelegateSessionStateTestProxy

- (void)reloadConfigAndApplyHotkey {
    self.reloadCount += 1;
}

- (void)reloadConfigAndApplyHotkeyIfSafe {
    if (!sessionStateAllowsConfigReloadForTest(self.sessionState)) {
        self.hasPendingConfigReload = YES;
        return;
    }

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

- (void)applyDeferredConfigReloadIfNeeded {
    if (!self.hasPendingConfigReload) return;
    if (!sessionStateAllowsConfigReloadForTest(self.sessionState)) return;

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

@end

@interface SPHotkeyMonitorTestDelegate : NSObject <SPHotkeyMonitorDelegate>
@property (nonatomic, assign) NSInteger holdStartCount;
@property (nonatomic, assign) NSInteger holdEndCount;
@property (nonatomic, assign) NSInteger tapStartCount;
@property (nonatomic, assign) NSInteger tapEndCount;
@end

@implementation SPHotkeyMonitorTestDelegate

- (void)hotkeyMonitorDidDetectHoldStart {
    self.holdStartCount += 1;
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    self.holdEndCount += 1;
}

- (void)hotkeyMonitorDidDetectTapStart {
    self.tapStartCount += 1;
}

- (void)hotkeyMonitorDidDetectTapEnd {
    self.tapEndCount += 1;
}

@end

@interface SPHotkeyMonitor (Tests)
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)holdTimerFired;
- (void)scheduleModifierRelease;
- (void)setRunning:(BOOL)running;
- (void)setTriggerDown:(BOOL)triggerDown;
- (NSUInteger)currentModifierFlags;
@end

static NSUInteger SPStubbedCurrentModifierFlags = 0;
static BOOL SPInstalledCurrentModifierFlagsStub = NO;

static NSUInteger SPCurrentModifierFlagsStub(id self, SEL _cmd) {
    return SPStubbedCurrentModifierFlags;
}

static void SPInstallCurrentModifierFlagsStub(void) {
    if (SPInstalledCurrentModifierFlagsStub) return;
    class_replaceMethod([SPHotkeyMonitor class],
                        @selector(currentModifierFlags),
                        (IMP)SPCurrentModifierFlagsStub,
                        "Q@:");
    SPInstalledCurrentModifierFlagsStub = YES;
}

@interface SPAppDelegateLogicTests : XCTestCase
@end

@implementation SPAppDelegateLogicTests

- (void)testDefersReloadDuringActiveSession {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"recording_hold";

    [proxy reloadConfigAndApplyHotkeyIfSafe];

    XCTAssertTrue(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 0);
}

- (void)testAppliesDeferredReloadOnceIdle {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"recording_toggle";

    [proxy reloadConfigAndApplyHotkeyIfSafe];
    XCTAssertTrue(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 0);

    proxy.sessionState = @"idle";
    [proxy applyDeferredConfigReloadIfNeeded];

    XCTAssertFalse(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 1);
}

- (void)testIdleReloadDoesNotDefer {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"idle";

    [proxy reloadConfigAndApplyHotkeyIfSafe];

    XCTAssertFalse(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 1);
}

- (void)testModifierReleaseDebounceDoesNotEndHoldWhileModifierStillDown {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = 0;
    SPStubbedCurrentModifierFlags = monitor.targetModifierFlag;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release verification window"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 0);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testModifierReleaseDebounceIgnoresBriefFalseRelease {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = 0;
    SPStubbedCurrentModifierFlags = 0;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release debounce window"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPStubbedCurrentModifierFlags = monitor.targetModifierFlag;
        [monitor setTriggerDown:YES];
        [monitor handleTriggerDown];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 0);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testModifierReleaseDebounceEndsHoldWhenReleasePersists {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = 0;
    SPStubbedCurrentModifierFlags = 0;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release debounce fires"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 1);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testToggleModeDoesNotEnterHoldFlowAfterLongPress {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = 1;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    XCTAssertEqual(delegate.holdStartCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);

    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.holdStartCount, 0);
    XCTAssertEqual(delegate.holdEndCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 1);
    XCTAssertEqual(delegate.tapEndCount, 0);
}

@end

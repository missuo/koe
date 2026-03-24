#import "SPAppDelegate.h"
#import "SPPermissionManager.h"
#import "SPHotkeyMonitor.h"
#import "SPAudioCaptureManager.h"
#import "SPAudioDeviceManager.h"
#import "SPRustBridge.h"
#import "SPClipboardManager.h"
#import "SPPasteManager.h"
#import "SPCuePlayer.h"
#import "SPStatusBarManager.h"
#import "SPOverlayPanel.h"
#import "SPHistoryManager.h"
#import "koe_core.h"
#import <sys/stat.h>
#import <UserNotifications/UserNotifications.h>

@interface SPAppDelegate ()
@property (nonatomic, strong) NSDate *recordingStartTime;
@property (nonatomic, assign) time_t lastConfigModTime;
@end

@implementation SPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[Koe] Application launching...");

    // Initialize components
    self.cuePlayer = [[SPCuePlayer alloc] init];
    self.clipboardManager = [[SPClipboardManager alloc] init];
    self.pasteManager = [[SPPasteManager alloc] init];
    self.audioCaptureManager = [[SPAudioCaptureManager alloc] init];
    self.audioDeviceManager = [[SPAudioDeviceManager alloc] init];
    self.permissionManager = [[SPPermissionManager alloc] init];

    // Initialize Rust bridge (must be before hotkey monitor)
    self.rustBridge = [[SPRustBridge alloc] initWithDelegate:self];
    [self.rustBridge initializeCore];

    // Initialize status bar
    self.statusBarManager = [[SPStatusBarManager alloc] initWithDelegate:self
                                                       permissionManager:self.permissionManager
                                                      audioDeviceManager:self.audioDeviceManager];

    // Initialize floating overlay
    self.overlayPanel = [[SPOverlayPanel alloc] init];

    // Request notification permission
    [self.permissionManager requestNotificationPermission];

    // Check permissions
    [self.permissionManager checkAllPermissionsWithCompletion:^(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted) {
        NSLog(@"[Koe] Permissions — mic:%d accessibility:%d inputMonitoring:%d",
              micGranted, accessibilityGranted, inputMonitoringGranted);

        if (!micGranted) {
            NSLog(@"[Koe] ERROR: Microphone permission not granted");
            [self.cuePlayer playError];
            return;
        }

        if (!inputMonitoringGranted) {
            NSLog(@"[Koe] WARNING: Input Monitoring probe failed, will attempt hotkey monitor anyway");
        }

        // Start hotkey monitor (let it try CGEventTap directly — the probe may give false negatives)
        self.hotkeyMonitor = [[SPHotkeyMonitor alloc] initWithDelegate:self];

        // Apply hotkey configuration from config.yaml
        struct SPHotkeyConfig hotkeyConfig = sp_core_get_hotkey_config();
        self.hotkeyMonitor.targetKeyCode = hotkeyConfig.key_code;
        self.hotkeyMonitor.altKeyCode = hotkeyConfig.alt_key_code;
        self.hotkeyMonitor.targetModifierFlag = hotkeyConfig.modifier_flag;

        [self.hotkeyMonitor start];
        NSLog(@"[Koe] Ready — hotkey monitor active");

        // Start watching config file for hotkey changes
        [self startConfigWatcher];
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[Koe] Application terminating...");
    if (self.configWatcher) {
        dispatch_source_cancel(self.configWatcher);
        self.configWatcher = nil;
    }
    [self.hotkeyMonitor stop];
    [self.rustBridge destroyCore];
}

#pragma mark - Config File Watcher

- (void)startConfigWatcher {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".koe/config.yaml"];

    // Record initial modification time
    struct stat st;
    if (stat(configPath.UTF8String, &st) == 0) {
        self.lastConfigModTime = st.st_mtime;
    }

    // Check config file modification every 3 seconds
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkConfigFileChanged];
    });

    dispatch_resume(timer);
    self.configWatcher = timer;
    NSLog(@"[Koe] Config file watcher started (polling every 3s)");
}

- (void)checkConfigFileChanged {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".koe/config.yaml"];

    struct stat st;
    if (stat(configPath.UTF8String, &st) != 0) return;

    if (st.st_mtime == self.lastConfigModTime) return;
    self.lastConfigModTime = st.st_mtime;

    NSLog(@"[Koe] Config file changed, reloading hotkey config...");

    // Reload config in Rust core
    [self.rustBridge reloadConfig];

    // Read new hotkey config
    struct SPHotkeyConfig newConfig = sp_core_get_hotkey_config();

    // Check if hotkey settings actually changed
    if (self.hotkeyMonitor.targetKeyCode != newConfig.key_code ||
        self.hotkeyMonitor.altKeyCode != newConfig.alt_key_code ||
        self.hotkeyMonitor.targetModifierFlag != newConfig.modifier_flag) {

        NSLog(@"[Koe] Hotkey changed: keyCode %ld→%d altKeyCode %ld→%d modifierFlag 0x%lx→0x%llx",
              (long)self.hotkeyMonitor.targetKeyCode, newConfig.key_code,
              (long)self.hotkeyMonitor.altKeyCode, newConfig.alt_key_code,
              (unsigned long)self.hotkeyMonitor.targetModifierFlag, (unsigned long long)newConfig.modifier_flag);

        // Stop, update, restart
        [self.hotkeyMonitor stop];
        self.hotkeyMonitor.targetKeyCode = newConfig.key_code;
        self.hotkeyMonitor.altKeyCode = newConfig.alt_key_code;
        self.hotkeyMonitor.targetModifierFlag = newConfig.modifier_flag;
        [self.hotkeyMonitor start];

        NSLog(@"[Koe] Hotkey monitor restarted with new trigger key");
    }
}

#pragma mark - SPHotkeyMonitorDelegate

- (void)hotkeyMonitorDidDetectHoldStart {
    NSLog(@"[Koe] Hold start detected");
    self.recordingStartTime = [NSDate date];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    // Start audio capture + Rust session
    [self.rustBridge beginSessionWithMode:SPSessionModeHold];
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    [self.audioCaptureManager startCaptureWithAudioCallback:^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
    }];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    NSLog(@"[Koe] Hold end detected");
    [self.cuePlayer playStop];

    // Keep recording for 800ms after Fn release to capture trailing speech,
    // then stop mic and end session
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
}

- (void)hotkeyMonitorDidDetectTapStart {
    NSLog(@"[Koe] Tap start detected");
    self.recordingStartTime = [NSDate date];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    [self.rustBridge beginSessionWithMode:SPSessionModeToggle];
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    [self.audioCaptureManager startCaptureWithAudioCallback:^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
    }];
}

- (void)hotkeyMonitorDidDetectTapEnd {
    NSLog(@"[Koe] Tap end detected");
    [self.cuePlayer playStop];

    // Keep recording for 800ms after tap-end to capture trailing speech,
    // then stop mic and end session
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
}

#pragma mark - SPRustBridgeDelegate

- (void)rustBridgeDidBecomeReady {
    NSLog(@"[Koe] Session ready (ASR connected)");
}

- (void)rustBridgeDidReceiveFinalText:(NSString *)text {
    NSLog(@"[Koe] Final text received (%lu chars)", (unsigned long)text.length);

    // Record history
    NSInteger durationMs = 0;
    if (self.recordingStartTime) {
        durationMs = (NSInteger)(-[self.recordingStartTime timeIntervalSinceNow] * 1000);
        self.recordingStartTime = nil;
    }
    [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs text:text];

    [self.statusBarManager updateState:@"pasting"];
    [self.overlayPanel updateState:@"pasting"];

    // Backup clipboard, write text, paste, restore
    [self.clipboardManager backup];
    [self.clipboardManager writeText:text];

    // Check if accessibility is available for auto-paste
    if ([self.permissionManager isAccessibilityGranted]) {
        [self.pasteManager simulatePasteWithCompletion:^{
            [self.clipboardManager scheduleRestoreAfterDelay:1500];
            [self.statusBarManager updateState:@"idle"];
            [self.overlayPanel updateState:@"idle"];
        }];
    } else {
        NSLog(@"[Koe] Accessibility not granted — text copied to clipboard only");
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
    }
}

- (void)rustBridgeDidEncounterError:(NSString *)message {
    NSLog(@"[Koe] Session error: %@", message);
    [self.cuePlayer playError];
    [self.audioCaptureManager stopCapture];
    [self.statusBarManager updateState:@"error"];
    [self.overlayPanel updateState:@"error"];

    // Send system notification with error details
    [self sendErrorNotification:message];

    // Brief error display, then back to idle
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
    });
}

- (void)sendWarningNotification:(NSString *)message {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Koe Warning";
    content.body = message;
    content.sound = nil;

    NSString *identifier = [NSString stringWithFormat:@"koe-warning-%f",
                            [[NSDate date] timeIntervalSince1970]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[Koe] Failed to deliver warning notification: %@", error.localizedDescription);
        }
    }];
}

- (void)sendErrorNotification:(NSString *)message {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Koe Error";
    content.body = message;
    content.sound = nil; // Already playing error cue

    NSString *identifier = [NSString stringWithFormat:@"koe-error-%f",
                            [[NSDate date] timeIntervalSince1970]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[Koe] Failed to deliver error notification: %@", error.localizedDescription);
        }
    }];
}

- (void)rustBridgeDidReceiveWarning:(NSString *)message {
    NSLog(@"[Koe] Session warning: %@", message);
    [self sendWarningNotification:message];
}

- (void)rustBridgeDidChangeState:(NSString *)state {
    [self.statusBarManager updateState:state];
    [self.overlayPanel updateState:state];
}

#pragma mark - SPStatusBarDelegate (menu)

- (void)statusBarMenuDidOpen {
    self.hotkeyMonitor.suspended = YES;
}

- (void)statusBarMenuDidClose {
    self.hotkeyMonitor.suspended = NO;
}

- (void)statusBarDidSelectQuit {
    [self.hotkeyMonitor stop];
    [NSApp terminate:nil];
}

- (void)statusBarDidSelectAudioDeviceWithUID:(NSString *)uid {
    NSLog(@"[Koe] Audio input device changed: %@", uid ?: @"System Default");
}

@end

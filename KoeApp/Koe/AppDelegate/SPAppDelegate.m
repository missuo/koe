#import "SPAppDelegate.h"
#import "SPPermissionManager.h"
#import "SPHotkeyMonitor.h"
#import "SPAudioCaptureManager.h"
#import "SPAudioDeviceManager.h"
#import "SPRustBridge.h"
#import "SPClipboardManager.h"
#import "SPClipboardRestorePolicy.h"
#import "SPPasteManager.h"
#import "SPInstantPasteGuard.h"
#import "SPCuePlayer.h"
#import "SPStatusBarManager.h"
#import "SPOverlayPanel.h"
#import "SPHistoryManager.h"
#import "SPSetupWizardWindowController.h"
#import <Sparkle/Sparkle.h>
#import "SPLocalization.h"
#import "koe_core.h"
#import <os/log.h>
#import <sys/stat.h>
#import <UserNotifications/UserNotifications.h>

@interface SPAppDelegate () <SPAudioDeviceManagerDelegate, SPOverlayPanelDelegate>
@property (nonatomic, strong) NSDate *recordingStartTime;
@property (nonatomic, assign) time_t lastConfigModTime;
@property (nonatomic, copy) dispatch_block_t pendingSessionEndBlock;
@property (nonatomic, assign) BOOL showingError;
@property (nonatomic, copy) NSString *lastAsrText;
// Session result metadata delivered just before the final text; consumed
// (and cleared) when the final text arrives and history is recorded.
@property (nonatomic, copy) NSString *pendingMetaAsrText;
@property (nonatomic, copy) NSString *pendingMetaAsrProvider;
@property (nonatomic, assign) BOOL pendingMetaLlmApplied;
// Experimental paste-ASR-first flow (experimental.paste_asr_first):
// raw text pasted at ASR-final time, awaiting the LLM correction.
@property (nonatomic, strong) SPInstantPasteGuard *instantPasteGuard;
// Session-scoped clipboard restoration policy; the effective delay is
// snapshotted when a session begins (see beginRustSessionWithMode:).
@property (nonatomic, strong) SPClipboardRestorePolicy *clipboardRestorePolicy;
@property (nonatomic, copy) NSString *instantPastedText;
@property (nonatomic, assign) BOOL instantPasteKeepClipboard;
@property (nonatomic, strong) id numberKeyMonitor;
@property (nonatomic, assign) BOOL llmCorrectionInProgress;
@property (nonatomic, assign) BOOL rawAsrFallbackInteractionActive;
@property (nonatomic, assign) BOOL sessionWantsAudioCapture;
@property (nonatomic, assign) BOOL audioPreparationEnabled;
@property (nonatomic, assign) BOOL preCaptureInterruptedPendingSessionEnd;
@property (nonatomic, assign) BOOL loggedFirstRecognitionForActivation;
@property (nonatomic, assign) NSUInteger recognitionMetricActivationSequence;
@property (nonatomic, assign) uint64_t recognitionMetricSessionToken;
@end

static BOOL sessionStateAllowsConfigReload(NSString *state) {
    if (state.length == 0) return YES;
    return [state isEqualToString:@"idle"] ||
           [state isEqualToString:@"completed"] ||
           [state isEqualToString:@"failed"] ||
           [state isEqualToString:@"error"];
}

@implementation SPAppDelegate

static const NSTimeInterval kManualPasteResultLingerDuration = 8.0;

static BOOL configFlagEnabled(const char *keyPath) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return NO;

    NSString *value = [[[NSString stringWithUTF8String:rawValue] ?: @""
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    sp_core_free_string(rawValue);
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)prepareAudioQueueForResolvedDevice {
    if (!self.audioPreparationEnabled) return NO;
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    return [self.audioCaptureManager prepare];
}

static BOOL configFlagEnabledWithDefault(const char *keyPath, BOOL defaultValue) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return defaultValue;

    BOOL enabled = defaultValue;
    if (strcmp(rawValue, "true") == 0) {
        enabled = YES;
    } else if (strcmp(rawValue, "false") == 0) {
        enabled = NO;
    }
    sp_core_free_string(rawValue);
    return enabled;
}

- (BOOL)shouldShowPromptTemplateButtons {
    return configFlagEnabled("llm.prompt_templates_enabled");
}

- (BOOL)shouldAutoPasteProcessedText {
    return configFlagEnabledWithDefault("llm.auto_paste_processed_text", YES);
}

- (void)showPromptTemplateButtonsIfNeededOrDismiss {
    [self showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:0];
}

- (void)showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:(NSTimeInterval)lingerDuration {
    [self startAnyKeyDismissMonitoring];

    if (![self shouldShowPromptTemplateButtons]) {
        [self.overlayPanel lingerAndDismissWithDuration:lingerDuration];
        return;
    }

    NSArray *templates = [self.rustBridge promptTemplates];
    NSMutableArray<NSDictionary *> *visibleTemplates = [NSMutableArray array];
    NSInteger visibleShortcut = 1;
    for (NSUInteger index = 0; index < templates.count; index++) {
        NSDictionary *templateData = templates[index];
        id enabledValue = templateData[@"enabled"];
        BOOL enabled = ![enabledValue isKindOfClass:[NSNumber class]] || [enabledValue boolValue];
        if (!enabled) continue;

        NSMutableDictionary *overlayTemplate = [templateData mutableCopy] ?: [NSMutableDictionary dictionary];
        overlayTemplate[@"shortcut"] = @(visibleShortcut++);
        overlayTemplate[@"source_index"] = @(index);
        [visibleTemplates addObject:overlayTemplate];
    }

    NSLog(@"[Koe] Prompt templates visible: %lu / %lu", (unsigned long)visibleTemplates.count, (unsigned long)templates.count);
    if (visibleTemplates.count > 0 && self.lastAsrText.length > 0) {
        [self.overlayPanel showTemplateButtons:visibleTemplates lingerDuration:lingerDuration];
        [self startNumberKeyMonitoring];
    } else {
        [self.overlayPanel lingerAndDismissWithDuration:lingerDuration];
    }
}

- (void)applyHotkeyConfig:(struct SPHotkeyConfig)hotkeyConfig restartMonitorIfNeeded:(BOOL)restartIfNeeded {
    BOOL changed = self.hotkeyMonitor.targetKeyCode != hotkeyConfig.trigger_key_code ||
                   self.hotkeyMonitor.altKeyCode != hotkeyConfig.trigger_alt_key_code ||
                   self.hotkeyMonitor.targetModifierFlag != hotkeyConfig.trigger_modifier_flag ||
                   self.hotkeyMonitor.targetMatchKind != hotkeyConfig.trigger_match_kind ||
                   self.hotkeyMonitor.triggerMode != (SPHotkeyTriggerMode)hotkeyConfig.trigger_mode;

    if (!changed) return;

    if (restartIfNeeded) {
        [self.hotkeyMonitor stop];
    }

    self.hotkeyMonitor.targetKeyCode = hotkeyConfig.trigger_key_code;
    self.hotkeyMonitor.altKeyCode = hotkeyConfig.trigger_alt_key_code;
    self.hotkeyMonitor.targetModifierFlag = hotkeyConfig.trigger_modifier_flag;
    self.hotkeyMonitor.targetMatchKind = hotkeyConfig.trigger_match_kind;
    self.hotkeyMonitor.triggerMode = (SPHotkeyTriggerMode)hotkeyConfig.trigger_mode;

    if (restartIfNeeded) {
        [self.hotkeyMonitor start];
    }
}

- (void)reloadConfigAndApplyHotkey {
    [self.rustBridge reloadConfig];

    struct SPHotkeyConfig newConfig = sp_core_get_hotkey_config();
    NSLog(@"[Koe] Reloaded hotkey config: trigger=%d/%d flag=0x%llx kind=%d",
          newConfig.trigger_key_code,
          newConfig.trigger_alt_key_code,
          (unsigned long long)newConfig.trigger_modifier_flag,
          newConfig.trigger_match_kind);

    [self applyHotkeyConfig:newConfig restartMonitorIfNeeded:YES];
    [self.overlayPanel reloadAppearanceFromConfig];
}

- (void)reloadConfigAndApplyHotkeyIfSafe {
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        self.hasPendingConfigReload = YES;
        NSLog(@"[Koe] Deferring config reload until session becomes idle (state=%@)", self.sessionState ?: @"unknown");
        return;
    }

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

- (void)applyDeferredConfigReloadIfNeeded {
    if (!self.hasPendingConfigReload) return;
    if (!sessionStateAllowsConfigReload(self.sessionState)) return;

    NSLog(@"[Koe] Applying deferred config reload");
    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[Koe] Application launching...");
    self.sessionState = @"idle";

    // Add Edit menu so Cmd+C/V/X/A work in text fields (menu-bar-only app has none by default)
    [self installEditMenu];

    // Initialize components
    self.cuePlayer = [[SPCuePlayer alloc] init];
    self.clipboardManager = [[SPClipboardManager alloc] init];
    self.clipboardRestorePolicy = [[SPClipboardRestorePolicy alloc] init];
    self.clipboardRestorePolicy.clipboardManager = self.clipboardManager;
    self.pasteManager = [[SPPasteManager alloc] init];
    self.instantPasteGuard = [[SPInstantPasteGuard alloc] init];
    self.audioCaptureManager = [[SPAudioCaptureManager alloc] init];
    self.audioDeviceManager = [[SPAudioDeviceManager alloc] init];
    self.audioDeviceManager.delegate = self;
    [self.audioDeviceManager startListening];
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
    self.overlayPanel.delegate = self;

    // Initialize Sparkle updater (feed URL and public key come from Info.plist)
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
                                                                           updaterDelegate:nil
                                                                        userDriverDelegate:nil];

    // Request notification permission
    [self.permissionManager requestNotificationPermission];

    // Request Speech Recognition permission if Apple Speech is the configured provider
    char *rawProvider = sp_config_get("asr.provider");
    if (rawProvider) {
        if (strcmp(rawProvider, "apple-speech") == 0) {
            [self.permissionManager requestSpeechRecognitionPermissionWithCompletion:^(BOOL granted) {
                NSLog(@"[Koe] Speech recognition permission: %@", granted ? @"granted" : @"denied");
                if (!granted) {
                    [self.permissionManager showPermissionAlertForType:SPPermissionTypeSpeechRecognition
                                                          settingsURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]];
                }
            }];
        }
        sp_core_free_string(rawProvider);
    }

    // Check permissions
    [self.permissionManager checkAllPermissionsWithCompletion:^(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted) {
        NSLog(@"[Koe] Permissions — mic:%d accessibility:%d inputMonitoring:%d",
              micGranted, accessibilityGranted, inputMonitoringGranted);

        if (!micGranted) {
            NSLog(@"[Koe] ERROR: Microphone permission not granted");
            [self.cuePlayer playError];
            [self.permissionManager showPermissionAlertForType:SPPermissionTypeMicrophone
                                                  settingsURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
            return;
        }

        // No app-level alerts for Accessibility / Input Monitoring at launch:
        // macOS shows its own Input Monitoring prompt when the event tap
        // starts, and the status bar menu offers grant actions for both.
        if (!accessibilityGranted) {
            NSLog(@"[Koe] WARNING: Accessibility permission not granted");
        }

        if (!inputMonitoringGranted) {
            NSLog(@"[Koe] WARNING: Input Monitoring probe failed, will attempt hotkey monitor anyway");
        }

        // Build the queue after TCC confirms microphone access, but do not
        // start hardware yet. The trigger-down path starts this prepared queue.
        self.audioPreparationEnabled = YES;
        if (![self prepareAudioQueueForResolvedDevice]) {
            NSLog(@"[Koe] Initial audio queue preparation failed; trigger-down will retry");
        }

        // Start hotkey monitor (let it try CGEventTap directly — the probe may give false negatives)
        self.hotkeyMonitor = [[SPHotkeyMonitor alloc] initWithDelegate:self];

        // Apply hotkey configuration from config.yaml
        struct SPHotkeyConfig hotkeyConfig = sp_core_get_hotkey_config();
        [self applyHotkeyConfig:hotkeyConfig restartMonitorIfNeeded:NO];

        [self.hotkeyMonitor start];
        NSLog(@"[Koe] Ready — hotkey monitor active");

        // Start watching config file for hotkey changes
        [self startConfigWatcher];
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[Koe] Application terminating...");
    self.quitting = YES;
    self.sessionWantsAudioCapture = NO;
    // Stop the hotkey monitor before any slow teardown so its event tap
    // cannot stall the session keyboard stream (see statusBarDidSelectQuit).
    // Safe to call twice — stop() is idempotent.
    [self.hotkeyMonitor stop];
    [self cancelPendingSessionEnd];
    // Cancel any scheduled CGEventPost paste/undo blocks. The status-bar quit
    // path already does this, but termination can also start elsewhere
    // (Sparkle update relaunch, logout/shutdown) — without the cancel, a
    // pending synthetic paste can still fire during run-loop draining and
    // leak key events into whichever app is focused.
    [self.pasteManager cancel];
    [self.audioCaptureManager shutdown];
    // Safety net: restore device mute even if capture state was already cleared.
    // Device mute is a persistent system property — leaving it on after quit is bad.
    [self.audioCaptureManager restoreMutedSystemOutputIfNeeded];
    if (self.configWatcher) {
        dispatch_source_cancel(self.configWatcher);
        self.configWatcher = nil;
    }
    [self.audioDeviceManager stopListening];
    [self.rustBridge destroyCore];
}

#pragma mark - Edit Menu (for Cmd+C/V in text fields)

- (void)installEditMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        mainMenu = [[NSMenu alloc] init];
        [NSApp setMainMenu:mainMenu];
    }

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"menu.edit") action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:KoeLocalizedString(@"menu.edit")];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.undo") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.redo") action:@selector(redo:) keyEquivalent:@"Z"];
#pragma clang diagnostic pop
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:KoeLocalizedString(@"menu.edit.selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];

    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];
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

    NSLog(@"[Koe] Config file changed, scheduling config reload...");

    [self reloadConfigAndApplyHotkeyIfSafe];
}

#pragma mark - SPHotkeyMonitorDelegate

- (void)cancelPendingSessionEnd {
    if (self.pendingSessionEndBlock) {
        dispatch_block_cancel(self.pendingSessionEndBlock);
        self.pendingSessionEndBlock = nil;
    }
}

- (void)hotkeyMonitorDidBeginTrigger {
    // This callback occurs on the initial key-down, before the 180ms hold/tap
    // decision. Starting the already-prepared queue here makes the microphone
    // privacy indicator and Bluetooth route activation begin immediately.
    if (self.pendingSessionEndBlock) {
        [self cancelPendingSessionEnd];
        self.preCaptureInterruptedPendingSessionEnd = YES;
    }
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    if (![self.audioCaptureManager beginPreCapture]) {
        NSLog(@"[Koe] Trigger-down audio pre-capture failed; confirmed session will retry");
    }
}

- (void)hotkeyMonitorDidCancelTrigger {
    [self.audioCaptureManager cancelPreCapture];
    if (self.preCaptureInterruptedPendingSessionEnd) {
        self.preCaptureInterruptedPendingSessionEnd = NO;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    }
}

/// Begin a Rust session and capture per-session state shared by the hold and
/// tap start paths. Returns NO (after surfacing the error) when the session
/// could not be started.
- (BOOL)beginRustSessionWithMode:(SPSessionModeObjC)mode {
    if (![self.rustBridge beginSessionWithMode:mode]) {
        [self handleAudioCaptureError:@"Failed to start session"];
        return NO;
    }
    // Snapshot the effective clipboard restoration policy for this session.
    // Rust hot-reloads config inside session_begin, so this is the validated
    // value governing this session; edits apply from the next session.
    [self.clipboardRestorePolicy
        captureSessionRestoreDelayMs:sp_core_get_clipboard_config().restore_delay_ms];
    self.loggedFirstRecognitionForActivation = NO;
    self.recognitionMetricActivationSequence = self.audioCaptureManager.activationSequence;
    self.recognitionMetricSessionToken = self.rustBridge.currentSessionToken;
    return YES;
}

- (void)hotkeyMonitorDidDetectHoldStart {
    NSLog(@"[Koe] Hold start detected");
    [self deactivateRawAsrFallbackInteraction];
    [self.audioCaptureManager logActivationMilestone:@"hold decision"];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.overlayPanel hideTemplateButtons];
    self.showingError = NO;
    [self cancelPendingSessionEnd];
    self.sessionWantsAudioCapture = YES;
    self.preCaptureInterruptedPendingSessionEnd = NO;
    if (self.audioCaptureManager.isCapturing && !self.audioCaptureManager.isPreCapturing) {
        [self.audioCaptureManager stopCapture];
    }

    self.recordingStartTime = [NSDate date];
    self.sessionState = @"recording_hold";
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    // Start Rust session + audio capture
    if (![self beginRustSessionWithMode:SPSessionModeHold]) return;
    [self startAudioCaptureWithRetryIncludingPreRoll:YES];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    NSLog(@"[Koe] Hold end detected");
    [self.cuePlayer playStop];

    // Keep recording for 300ms after Fn release to capture trailing speech,
    // then stop mic and end session.  Use a cancellable block so a rapid
    // re-press can prevent the stale endSession from killing the new session.
    [self cancelPendingSessionEnd];
    self.preCaptureInterruptedPendingSessionEnd = NO;
    dispatch_block_t block = dispatch_block_create(0, ^{
        self.pendingSessionEndBlock = nil;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
    self.pendingSessionEndBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), block);
}

- (void)hotkeyMonitorDidDetectTapStart {
    NSLog(@"[Koe] Tap start detected");
    [self deactivateRawAsrFallbackInteraction];
    [self.audioCaptureManager logActivationMilestone:@"tap decision"];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.overlayPanel hideTemplateButtons];
    self.showingError = NO;
    [self cancelPendingSessionEnd];
    self.sessionWantsAudioCapture = YES;
    self.preCaptureInterruptedPendingSessionEnd = NO;
    if (self.audioCaptureManager.isCapturing && !self.audioCaptureManager.isPreCapturing) {
        [self.audioCaptureManager stopCapture];
    }

    self.recordingStartTime = [NSDate date];
    self.sessionState = @"recording_toggle";
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    if (![self beginRustSessionWithMode:SPSessionModeToggle]) return;
    [self startAudioCaptureWithRetryIncludingPreRoll:NO];
}

- (void)hotkeyMonitorDidDetectTapEnd {
    NSLog(@"[Koe] Tap end detected");
    [self.cuePlayer playStop];

    // Keep recording for 300ms after tap-end to capture trailing speech,
    // then stop mic and end session.  Use a cancellable block (same as hold).
    [self cancelPendingSessionEnd];
    dispatch_block_t block = dispatch_block_create(0, ^{
        self.pendingSessionEndBlock = nil;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
    self.pendingSessionEndBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), block);
}

#pragma mark - Audio Capture Start with Retry

- (void)startAudioCaptureWithRetryIncludingPreRoll:(BOOL)includePreRoll {
    struct SPFeedbackConfig feedbackConfig = sp_core_get_feedback_config();
    self.audioCaptureManager.muteOutputEnabled = feedbackConfig.mute_system_output;
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    uint64_t token = self.rustBridge.currentSessionToken;
    SPAudioFrameCallback callback = ^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
    };

    // AudioQueue capture starts cheaply without blocking the main thread, so a
    // synchronous start is fine here.
    if ([self.audioCaptureManager startCaptureWithAudioCallback:callback
                                                 includePreRoll:includePreRoll]) return;

    // After a device route change or fresh permission grant the audio
    // subsystem may need a moment to settle. Retry once after a short delay.
    NSLog(@"[Koe] Audio capture failed on first attempt, retrying in 500ms...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        if (self.quitting) return;
        if (!self.sessionWantsAudioCapture) return;

        struct SPFeedbackConfig retryFeedback = sp_core_get_feedback_config();
        self.audioCaptureManager.muteOutputEnabled = retryFeedback.mute_system_output;
        [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
        if ([self.audioCaptureManager startCaptureWithAudioCallback:callback
                                                     includePreRoll:includePreRoll]) {
            NSLog(@"[Koe] Audio capture started on retry");
            return;
        }
        [self handleAudioCaptureError:@"Failed to start audio capture"];
    });
}

#pragma mark - SPRustBridgeDelegate

- (void)rustBridgeDidBecomeReady {
    NSLog(@"[Koe] Session ready (ASR connected)");
    // A fresh session invalidates any instant-paste state from a session
    // that was cancelled between its raw paste and its LLM correction.
    self.instantPastedText = nil;
    [self.instantPasteGuard reset];
    if (self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        [self.audioCaptureManager logActivationMilestone:@"ASR ready"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
}

- (void)rustBridgeDidReceiveFinalText:(NSString *)text {
    if (self.quitting) return;
    self.sessionState = @"idle";
    NSLog(@"[Koe] Final text received (%lu chars)", (unsigned long)text.length);
    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];

    // Record history
    NSInteger durationMs = 0;
    if (self.recordingStartTime) {
        durationMs = (NSInteger)(-[self.recordingStartTime timeIntervalSinceNow] * 1000);
        self.recordingStartTime = nil;
    }
    [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs
                                                             text:text
                                                          asrText:self.pendingMetaAsrText
                                                      asrProvider:self.pendingMetaAsrProvider
                                                       llmApplied:self.pendingMetaLlmApplied];
    self.pendingMetaAsrText = nil;
    self.pendingMetaAsrProvider = nil;
    self.pendingMetaLlmApplied = NO;

    // Experimental paste-ASR-first flow: the raw text is already in the
    // target app; apply the correction in place instead of pasting again.
    if ([self finishInstantPasteWithFinalText:text]) return;

    uint64_t token = self.rustBridge.currentSessionToken;
    BOOL shouldAutoPaste = [self shouldAutoPasteProcessedText];
    BOOL accessOK = [self.permissionManager isAccessibilityGranted];
    BOOL canAutoPaste = shouldAutoPaste && accessOK;
    NSLog(@"[Koe] Accessibility granted: %@", accessOK ? @"YES" : @"NO");

    if (canAutoPaste) {
        // Show corrected text in overlay before pasting
        [self.overlayPanel updateDisplayText:text];
        [self.statusBarManager updateState:@"pasting"];
        [self.overlayPanel updateState:@"pasting"];

        // Auto-paste flow temporarily backs up the clipboard, then restores it.
        [self.clipboardManager backup];
        [self.clipboardManager writeText:text];

        BOOL autoReturn = configFlagEnabled("paste.auto_return");
        [self.pasteManager simulatePasteWithCompletion:^{
            NSLog(@"[Koe] Paste completion callback fired");
            if (autoReturn) {
                [self.pasteManager simulateReturnKey];
            }
            [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
            if (token != self.rustBridge.currentSessionToken) return;
            [self.statusBarManager updateState:@"idle"];
            [self showPromptTemplateButtonsIfNeededOrDismiss];
        }];
    } else {
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeText:text];

        NSString *displayText = text;
        NSTimeInterval lingerDuration = 0;
        if (!shouldAutoPaste) {
            NSLog(@"[Koe] Auto-paste disabled — processed text copied to clipboard only");
            displayText = [text stringByAppendingString:@"  ✓ Copied"];
            lingerDuration = kManualPasteResultLingerDuration;
        } else {
            NSLog(@"[Koe] Accessibility not granted — text copied to clipboard only");
        }

        [self.overlayPanel updateDisplayText:displayText];
        [self.overlayPanel updateState:@"pasting"];
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:lingerDuration];
    }

    [self applyDeferredConfigReloadIfNeeded];
}

- (void)rustBridgeDidEncounterError:(NSString *)message {
    if (self.quitting) return;
    self.sessionState = @"failed";
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[Koe] Session error: %{public}@", message ?: @"unknown error");
    NSLog(@"[Koe] Session error: %@", message);
    self.showingError = YES;
    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];
    self.instantPastedText = nil;
    [self.instantPasteGuard reset];
    [self.cuePlayer playError];
    self.sessionWantsAudioCapture = NO;
    [self.audioCaptureManager stopCapture];
    [self.hotkeyMonitor resetToIdle];
    [self.statusBarManager updateState:@"error"];
    [self.overlayPanel updateState:@"error"];
    [self.overlayPanel updateDisplayText:[self localizedErrorSummary:message]];

    // Send system notification with error details
    [self sendErrorNotification:message];

    // Brief error display, then back to idle.
    // Guard with session token so a new session isn't reset to idle.
    uint64_t token = self.rustBridge.currentSessionToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        self.showingError = NO;
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self applyDeferredConfigReloadIfNeeded];
    });
}

- (NSString *)localizedErrorSummary:(NSString *)message {
    if (!message.length) return KoeLocalizedString(@"error.asr.unknown");
    NSString *lower = message.lowercaseString;
    if ([lower containsString:@"timed out"] || [lower containsString:@"timeout"]) {
        return KoeLocalizedString(@"error.asr.timeout");
    }
    if ([lower containsString:@"starttask"] || [lower containsString:@"startsession"]) {
        return KoeLocalizedString(@"error.asr.service");
    }
    if ([lower containsString:@"credential"] || [lower containsString:@"token"] || [lower containsString:@"auth"]) {
        return KoeLocalizedString(@"error.asr.auth");
    }
    if ([lower containsString:@"microphone"] || [lower containsString:@"audio"]) {
        return KoeLocalizedString(@"error.audio");
    }
    return KoeLocalizedString(@"error.asr.unknown");
}

- (void)sendWarningNotification:(NSString *)message {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = KoeLocalizedString(@"notification.warning.title");
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
    content.title = KoeLocalizedString(@"notification.error.title");
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
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[Koe] Session warning: %{public}@", message ?: @"unknown warning");
    NSLog(@"[Koe] Session warning: %@", message);
    [self sendWarningNotification:message];
}

- (void)rustBridgeDidReceiveInterimText:(NSString *)text {
    if (!self.loggedFirstRecognitionForActivation && text.length > 0 &&
        self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        self.loggedFirstRecognitionForActivation = YES;
        [self.audioCaptureManager logActivationMilestone:@"first recognition result"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
    [self.overlayPanel updateInterimText:text];
}

- (void)rustBridgeDidReceiveAsrFinalText:(NSString *)text {
    NSLog(@"[Koe] ASR final text: %lu chars", (unsigned long)text.length);
    if (!self.loggedFirstRecognitionForActivation && text.length > 0 &&
        self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        self.loggedFirstRecognitionForActivation = YES;
        [self.audioCaptureManager logActivationMilestone:@"first recognition result"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
    self.lastAsrText = text;
    [self.overlayPanel updateDisplayText:text];
    [self activateRawAsrFallbackInteractionIfPossible];

    [self maybeInstantPasteAsrText:text];
}

#pragma mark - Experimental: paste ASR first, correct after LLM

/// Paste the raw ASR text as soon as recognition finishes, so the user sees
/// text land immediately instead of waiting out the LLM round-trip. The
/// correction is applied in place later — only when SPInstantPasteGuard can
/// prove the insertion is untouched — or delivered via clipboard otherwise.
- (void)maybeInstantPasteAsrText:(NSString *)text {
    if (self.quitting || text.length == 0) return;
    if (!configFlagEnabled("experimental.paste_asr_first")) return;
    if (![self.permissionManager isAccessibilityGranted]) return;

    NSLog(@"[Koe] InstantPaste: pasting raw ASR text (%lu chars)", (unsigned long)text.length);
    self.instantPastedText = text;
    self.instantPasteKeepClipboard = NO;
    [self.instantPasteGuard reset];

    [self.clipboardManager backup];
    [self.clipboardManager writeText:text];

    uint64_t token = self.rustBridge.currentSessionToken;
    [self.pasteManager simulatePasteWithCompletion:^{
        // The correction may have replaced the clipboard content already
        // (fast LLM); in that case the backup must not be restored over it.
        if (!self.instantPasteKeepClipboard) {
            [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
        }
        if (token != self.rustBridge.currentSessionToken) return;
        // Only capture when the correction hasn't been handled yet.
        if ([text isEqualToString:self.instantPastedText]) {
            [self.instantPasteGuard captureAfterPasteWithRawText:text];
        }
    }];
}

/// Handle the corrected text for a session whose raw ASR text was already
/// pasted. Returns YES when the instant-paste flow consumed the final text.
- (BOOL)finishInstantPasteWithFinalText:(NSString *)text {
    if (!self.instantPastedText) return NO;
    NSString *raw = self.instantPastedText;
    self.instantPastedText = nil;

    [self.overlayPanel updateDisplayText:text];

    if ([text isEqualToString:raw]) {
        // Nothing to correct; the raw paste already delivered the result.
        [self.instantPasteGuard reset];
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismiss];
    } else if ([self.instantPasteGuard replaceWithCorrectedText:text]) {
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismiss];
    } else {
        // Cannot prove in-place replacement is safe (focus moved, user
        // typed, or the app lacks accessibility text support). Leave the
        // raw text alone and deliver the correction via clipboard.
        self.instantPasteKeepClipboard = YES;
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeText:text];
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateDisplayText:[text stringByAppendingString:@"  ✓ Copied"]];
        [self.overlayPanel updateState:@"pasting"];
        [self.overlayPanel lingerAndDismiss];
    }

    [self applyDeferredConfigReloadIfNeeded];
    return YES;
}

- (void)rustBridgeDidReceiveSessionMetaWithAsrText:(NSString *)asrText
                                          provider:(NSString *)provider
                                        llmApplied:(BOOL)llmApplied {
    self.pendingMetaAsrText = asrText;
    self.pendingMetaAsrProvider = provider;
    self.pendingMetaLlmApplied = llmApplied;
}

- (void)rustBridgeDidReceiveRewriteText:(NSString *)text {
    NSLog(@"[Koe] Rewrite text received (%lu chars)", (unsigned long)text.length);

    [self.clipboardManager cancelPendingRestore];

    // Copy to clipboard (no auto-paste — user decides where to paste)
    [self.clipboardManager writeText:text];

    // Show result with "Copied" indicator
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateDisplayText:[text stringByAppendingString:@"  ✓ Copied"]];
    [self.overlayPanel updateState:@"pasting"];
    [self.overlayPanel lingerAndDismiss];
}

- (void)rustBridgeDidChangeState:(NSString *)state {
    if (self.quitting || self.showingError) return;
    self.sessionState = state;
    BOOL isCorrecting = [state isEqualToString:@"correcting"];
    if (isCorrecting) {
        self.llmCorrectionInProgress = YES;
    } else if ([state hasPrefix:@"recording"] ||
               [state isEqualToString:@"preparing_paste"] ||
               [state isEqualToString:@"pasting"] ||
               [state isEqualToString:@"cancelled"] ||
               [state isEqualToString:@"idle"] ||
               [state isEqualToString:@"failed"]) {
        self.llmCorrectionInProgress = NO;
        [self deactivateRawAsrFallbackInteraction];
    }
    [self.statusBarManager updateState:state];
    [self.overlayPanel updateState:state];
    if (isCorrecting) {
        [self activateRawAsrFallbackInteractionIfPossible];
    }
    [self applyDeferredConfigReloadIfNeeded];
}

#pragma mark - Raw ASR Fallback

- (void)activateRawAsrFallbackInteractionIfPossible {
    if (!self.llmCorrectionInProgress || self.lastAsrText.length == 0) return;

    self.rawAsrFallbackInteractionActive = YES;
    [self.overlayPanel setRawAsrFallbackClickEnabled:YES];

    // Assign the handler first: for modifier-only triggers the monitor runs
    // a listen-only tap and only upgrades to a consuming tap while an Enter
    // handler is installed, so canConsumeGlobalKeyEvents is meaningful only
    // after this assignment.
    __weak typeof(self) weakSelf = self;
    self.hotkeyMonitor.enterKeyHandler = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        return [strongSelf requestRawAsrFallbackFromUserAction:@"enter"];
    };
    if (!self.hotkeyMonitor.canConsumeGlobalKeyEvents) {
        self.hotkeyMonitor.enterKeyHandler = nil;
    }
}

- (void)deactivateRawAsrFallbackInteraction {
    self.rawAsrFallbackInteractionActive = NO;
    self.hotkeyMonitor.enterKeyHandler = nil;
    [self.overlayPanel setRawAsrFallbackClickEnabled:NO];
}

- (BOOL)requestRawAsrFallbackFromUserAction:(NSString *)action {
    if (!self.rawAsrFallbackInteractionActive || self.lastAsrText.length == 0) {
        return NO;
    }

    BOOL accepted = [self.rustBridge acceptAsrResult];
    NSLog(@"[Koe] Raw ASR fallback requested via %@ (%@)",
          action ?: @"unknown",
          accepted ? @"sent" : @"not active");

    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];
    // Consume the triggering event even if the Rust send failed: a failure
    // means the correction already finished and its final text is in flight,
    // so letting the Return through would type a stray newline right before
    // the paste lands.
    return YES;
}

#pragma mark - Audio Error Recovery

- (void)handleAudioCaptureError:(NSString *)reason {
    NSLog(@"[Koe] Audio capture error: %@", reason);
    [self.audioCaptureManager cancelPreCapture];
    [self.audioCaptureManager stopCapture];
    self.sessionState = @"error";
    self.showingError = YES;
    [self.cuePlayer playError];
    self.sessionWantsAudioCapture = NO;
    [self.rustBridge cancelSession];
    [self.hotkeyMonitor resetToIdle];
    [self.statusBarManager updateState:@"error"];
    [self.overlayPanel updateState:@"error"];
    [self sendErrorNotification:reason];

    uint64_t token = self.rustBridge.currentSessionToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        self.showingError = NO;
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self applyDeferredConfigReloadIfNeeded];
    });
}

#pragma mark - SPAudioDeviceManagerDelegate

- (void)audioDeviceManagerDeviceListDidChange {
    if (!self.audioPreparationEnabled) return;

    // If the selected device disappeared mid-recording, stop gracefully
    if (![self.audioDeviceManager isSelectedDeviceAvailable]) {
        NSLog(@"[Koe] Selected audio device disappeared during recording");
        BOOL wasCapturing = self.audioCaptureManager.isCapturing;
        [self.audioCaptureManager shutdown];

        if (wasCapturing) {
            [self handleAudioCaptureError:@"Audio device disconnected"];
        } else {
            [self prepareAudioQueueForResolvedDevice];
        }
    } else if (!self.audioCaptureManager.isAudioQueueRunning) {
        // Device-list and default-route changes can invalidate even an
        // inactive AudioQueue. Rebuild so Bluetooth reconnects never retain a
        // stale device and system-default selection resolves on next start.
        [self.audioCaptureManager shutdown];
        [self prepareAudioQueueForResolvedDevice];
    }
}

#pragma mark - SPStatusBarDelegate (menu)

- (void)statusBarMenuDidOpen {
    self.hotkeyMonitor.suspended = YES;
}

- (void)statusBarMenuDidClose {
    // Defer unsuspend to the next run-loop iteration so that any menu-item
    // action (e.g. Quit → stop()) executes first.  Without this, Cocoa's
    // menuDidClose: fires before the item action, resetting suspended=NO
    // and allowing FlagsChanged events through the NSEvent monitor path
    // before stop() has a chance to set running=NO.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.quitting) return;
        self.hotkeyMonitor.suspended = NO;
    });
}

- (void)statusBarDidSelectQuit {
    self.quitting = YES;
    self.sessionWantsAudioCapture = NO;
    self.hotkeyMonitor.suspended = YES;

    // Stop the hotkey monitor FIRST, before any slow teardown (audio, Rust).
    // While the monitor's event tap is alive, a blocked process stalls the
    // session's keyboard stream: keystrokes get swallowed and WindowServer
    // accumulates stale modifier state that it flushes as phantom
    // FlagsChanged events when the tap dies (issues #57/#65).
    [self.hotkeyMonitor stop];

    // Cancel any pending session-end block so it cannot trigger a paste
    // during the run-loop draining inside [NSApp terminate:].
    [self cancelPendingSessionEnd];
    // Cancel any scheduled CGEventPost paste/undo blocks so they cannot leak
    // synthetic key events into whichever app gains focus after Koe quits.
    [self.pasteManager cancel];
    [self.audioCaptureManager shutdown];
    [self.rustBridge cancelSession];
    [NSApp terminate:nil];
}

- (void)statusBarDidSelectAudioDeviceWithUID:(NSString *)uid {
    NSLog(@"[Koe] Audio input device changed: %@", uid ?: @"System Default");
    if (self.audioCaptureManager.isCapturing) return;

    [self.audioCaptureManager shutdown];
    [self prepareAudioQueueForResolvedDevice];
}

- (void)statusBarDidSelectSetupWizard {
    if (!self.setupWizard) {
        self.setupWizard = [[SPSetupWizardWindowController alloc] init];
        self.setupWizard.delegate = self;
        self.setupWizard.rustBridge = self.rustBridge;
    }
    [self.setupWizard showWindow:nil];
}

- (void)statusBarDidSelectCheckForUpdates {
    [self.updaterController checkForUpdates:nil];
}

#pragma mark - SPSetupWizardDelegate

- (void)setupWizardDidSaveConfig {
    NSLog(@"[Koe] Setup wizard saved config, scheduling reload...");

    if (![self shouldShowPromptTemplateButtons]) {
        [self stopNumberKeyMonitoring];
        [self stopAnyKeyDismissMonitoring];
        [self.overlayPanel hideTemplateButtons];
    }

    [self reloadConfigAndApplyHotkeyIfSafe];
    if (!self.hasPendingConfigReload) {
        NSLog(@"[Koe] Config reloaded after setup wizard save");
    }
}

#pragma mark - SPOverlayPanelDelegate

- (void)overlayPanelDidDismiss:(id)panel {
    [self deactivateRawAsrFallbackInteraction];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
}

- (void)overlayPanelDidRequestRawAsrFallback:(id)panel {
    [self requestRawAsrFallbackFromUserAction:@"overlay-click"];
}

- (void)overlayPanel:(id)panel didSelectTemplateAtIndex:(NSInteger)templateIndex {
    NSLog(@"[Koe] Template selected: index %ld", (long)templateIndex);
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.clipboardManager cancelPendingRestore];

    // Show rewriting state
    [self.overlayPanel updateState:@"correcting"];

    // Trigger rewrite
    if (![self.rustBridge rewriteWithTemplateIndex:templateIndex asrText:self.lastAsrText]) {
        NSLog(@"[Koe] Rewrite failed to start");
        [self.overlayPanel lingerAndDismiss];
    }
}

#pragma mark - Number Key Monitoring

- (void)startNumberKeyMonitoring {
    __weak typeof(self) weakSelf = self;
    // Assign the handler first: for modifier-only triggers the monitor runs
    // a listen-only tap and only upgrades to a consuming tap while a number
    // handler is installed, so canConsumeGlobalKeyEvents is meaningful only
    // after this assignment.
    self.hotkeyMonitor.numberKeyHandler = ^BOOL(NSInteger number) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;

        BOOL handled = [strongSelf.overlayPanel handleNumberKey:number];
        if (handled) {
            NSLog(@"[Koe] Template shortcut triggered: %ld", (long)number);
        }
        return handled;
    };

    if (!self.hotkeyMonitor.canConsumeGlobalKeyEvents) {
        self.hotkeyMonitor.numberKeyHandler = nil;
        NSLog(@"[Koe] Template selector visible (click-only; global number shortcuts unavailable without an active suppressing event tap)");
        return;
    }
    NSLog(@"[Koe] Template selector visible (global number shortcuts active)");
}

- (void)stopNumberKeyMonitoring {
    self.hotkeyMonitor.numberKeyHandler = nil;
    NSLog(@"[Koe] Template selector hidden");
}

#pragma mark - Any-Key Dismiss Monitoring

- (void)startAnyKeyDismissMonitoring {
    __weak typeof(self) weakSelf = self;
    self.hotkeyMonitor.anyKeyDismissHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSLog(@"[Koe] Key press detected — dismissing overlay immediately");
        [strongSelf stopNumberKeyMonitoring];
        [strongSelf stopAnyKeyDismissMonitoring];
        [strongSelf.overlayPanel dismissToIdle];
    };
    NSLog(@"[Koe] Any-key dismiss monitoring active");
}

- (void)stopAnyKeyDismissMonitoring {
    self.hotkeyMonitor.anyKeyDismissHandler = nil;
}

@end

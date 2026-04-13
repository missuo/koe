#import "SPPermissionManager.h"
#import "SPLocalization.h"
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <Speech/Speech.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const kDontRemindPrefix = @"KoePermissionDontRemind_";

@implementation SPPermissionManager

- (void)checkAllPermissionsWithCompletion:(SPPermissionCheckCompletion)completion {
    // Check microphone permission (async)
    [self requestMicrophonePermissionWithCompletion:^(BOOL micGranted) {
        [self requestAccessibilityPermission];
        BOOL accessibility = [self isAccessibilityGranted];
        BOOL inputMonitoring = [self isInputMonitoringGranted];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(micGranted, accessibility, inputMonitoring);
        });
    }];
}

- (void)requestMicrophonePermissionWithCompletion:(void (^)(BOOL))completion {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        completion(YES);
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            completion(granted);
        }];
    } else {
        NSLog(@"[Koe] Microphone permission denied or restricted");
        completion(NO);
    }
}

- (BOOL)isMicrophoneGranted {
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
}

- (BOOL)isAccessibilityGranted {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)requestAccessibilityPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static CGEventRef inputMonitoringProbeCallback(CGEventTapProxy proxy,
                                                CGEventType type,
                                                CGEventRef event,
                                                void *userInfo) {
    return event;
}

- (BOOL)isInputMonitoringGranted {
    // Probe by attempting to create a CGEventTap.
    // Must provide a valid callback — NULL callback can return NULL even with permission.
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionListenOnly,
                                         mask,
                                         inputMonitoringProbeCallback,
                                         NULL);
    if (tap) {
        CFRelease(tap);
        return YES;
    }
    return NO;
}

- (BOOL)isSpeechRecognitionGranted {
    return [SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusAuthorized;
}

- (void)requestSpeechRecognitionPermissionWithCompletion:(void (^)(BOOL))completion {
    SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
    if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        completion(YES);
    } else if (status == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(newStatus == SFSpeechRecognizerAuthorizationStatusAuthorized);
            });
        }];
    } else {
        NSLog(@"[Koe] Speech recognition permission denied or restricted");
        completion(NO);
    }
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[Koe] Notification permission request error: %@", error.localizedDescription);
        } else {
            NSLog(@"[Koe] Notification permission %@", granted ? @"granted" : @"denied");
        }
    }];
}

- (void)checkNotificationPermissionWithCompletion:(void (^)(BOOL granted))completion {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        BOOL granted = (settings.authorizationStatus == UNAuthorizationStatusAuthorized);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(granted);
        });
    }];
}

#pragma mark - Permission Alerts

- (NSString *)dontRemindKeyForType:(SPPermissionType)type {
    return [NSString stringWithFormat:@"%@%ld", kDontRemindPrefix, (long)type];
}

- (BOOL)isDontRemindSetForType:(SPPermissionType)type {
    return [[NSUserDefaults standardUserDefaults] boolForKey:[self dontRemindKeyForType:type]];
}

- (void)setDontRemindForType:(SPPermissionType)type {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:[self dontRemindKeyForType:type]];
}

- (void)resetDontRemindForType:(SPPermissionType)type {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self dontRemindKeyForType:type]];
}

- (BOOL)showPermissionAlertForType:(SPPermissionType)type
                       settingsURL:(nullable NSURL *)settingsURL {
    if ([self isDontRemindSetForType:type]) {
        return NO;
    }

    NSString *title = nil;
    NSString *message = nil;

    switch (type) {
        case SPPermissionTypeMicrophone:
            title = KoeLocalizedString(@"permission.microphone.title");
            message = KoeLocalizedString(@"permission.microphone.message");
            break;
        case SPPermissionTypeAccessibility:
            title = KoeLocalizedString(@"permission.accessibility.title");
            message = KoeLocalizedString(@"permission.accessibility.message");
            break;
        case SPPermissionTypeInputMonitoring:
            title = KoeLocalizedString(@"permission.inputMonitoring.title");
            message = KoeLocalizedString(@"permission.inputMonitoring.message");
            break;
        case SPPermissionTypeSpeechRecognition:
            title = KoeLocalizedString(@"permission.speechRecognition.title");
            message = KoeLocalizedString(@"permission.speechRecognition.message");
            break;
    }

    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;

    if (settingsURL) {
        [alert addButtonWithTitle:KoeLocalizedString(@"permission.button.openSettings")];
    }
    [alert addButtonWithTitle:KoeLocalizedString(@"permission.button.dismiss")];
    [alert addButtonWithTitle:KoeLocalizedString(@"permission.button.dontRemind")];

    NSModalResponse response = [alert runModal];

    if (settingsURL && response == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:settingsURL];
    }

    // "Don't Remind Again" is the last button
    NSModalResponse dontRemindResponse = settingsURL ? NSAlertThirdButtonReturn : NSAlertSecondButtonReturn;
    if (response == dontRemindResponse) {
        [self setDontRemindForType:type];
    }

    return YES;
}

@end

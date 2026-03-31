#import "SPPermissionManager.h"
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <UserNotifications/UserNotifications.h>

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

@end

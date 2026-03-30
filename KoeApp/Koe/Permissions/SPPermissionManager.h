#import <Foundation/Foundation.h>

typedef void (^SPPermissionCheckCompletion)(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted);

@interface SPPermissionManager : NSObject

- (void)checkAllPermissionsWithCompletion:(SPPermissionCheckCompletion)completion;
- (BOOL)isMicrophoneGranted;
- (BOOL)isAccessibilityGranted;
- (BOOL)isInputMonitoringGranted;

/// Check whether speech recognition permission has been granted.
- (BOOL)isSpeechRecognitionGranted;

/// Request speech recognition permission from the user.
- (void)requestSpeechRecognitionPermissionWithCompletion:(void (^)(BOOL granted))completion;

/// Request notification permission from the user.
- (void)requestNotificationPermission;

/// Check whether notification permission has been granted.
/// @param completion Called on main queue with the current authorization status.
- (void)checkNotificationPermissionWithCompletion:(void (^)(BOOL granted))completion;

@end

#import <Foundation/Foundation.h>

typedef void (^SPPermissionCheckCompletion)(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted);

/// Permission identifiers for alert throttling.
typedef NS_ENUM(NSInteger, SPPermissionType) {
    SPPermissionTypeMicrophone = 0,
    SPPermissionTypeAccessibility,
    SPPermissionTypeInputMonitoring,
    SPPermissionTypeSpeechRecognition,
};

@interface SPPermissionManager : NSObject

- (void)checkAllPermissionsWithCompletion:(SPPermissionCheckCompletion)completion;
- (BOOL)isMicrophoneGranted;
- (BOOL)isAccessibilityGranted;
- (void)requestAccessibilityPermission;
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

/// Show a permission alert for the given permission type. Respects
/// per-permission "don't remind again" preference stored in NSUserDefaults.
/// Returns YES if the alert was shown, NO if suppressed.
/// @param type The permission to alert about.
/// @param settingsURL If non-nil, the primary button opens this URL.
- (BOOL)showPermissionAlertForType:(SPPermissionType)type
                       settingsURL:(nullable NSURL *)settingsURL;

/// Reset the "don't remind again" flag for a specific permission.
- (void)resetDontRemindForType:(SPPermissionType)type;

@end

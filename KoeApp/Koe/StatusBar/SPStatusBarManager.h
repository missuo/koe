#import <Cocoa/Cocoa.h>

@class SPPermissionManager;
@class SPAudioDeviceManager;

@protocol SPStatusBarDelegate <NSObject>
@optional
- (void)statusBarDidSelectReloadConfig;
- (void)statusBarDidSelectQuit;
- (void)statusBarDidSelectSetupWizard;
- (void)statusBarDidSelectCheckForUpdates;
- (void)statusBarMenuDidOpen;
- (void)statusBarMenuDidClose;
- (void)statusBarDidSelectAudioDeviceWithUID:(nullable NSString *)uid;
/// Start a hands-free session when idle, end the running one while recording.
- (void)statusBarDidSelectToggleVoiceInput;
@end

NS_ASSUME_NONNULL_BEGIN

@interface SPStatusBarManager : NSObject <NSMenuDelegate>

- (instancetype)initWithDelegate:(nullable id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager;

/// Update the status bar icon and status text.
/// state: "idle", "recording_hold", "recording_toggle", "connecting_asr",
///        "finalizing_asr", "correcting", "preparing_paste", "pasting", "error", "completed"
- (void)updateState:(NSString *)state;

@end

NS_ASSUME_NONNULL_END

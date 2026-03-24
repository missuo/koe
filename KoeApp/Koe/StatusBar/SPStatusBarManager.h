#import <Cocoa/Cocoa.h>

@class SPPermissionManager;
@class SPAudioDeviceManager;

@protocol SPStatusBarDelegate <NSObject>
@optional
- (void)statusBarDidSelectReloadConfig;
- (void)statusBarDidSelectQuit;
- (void)statusBarMenuDidOpen;
- (void)statusBarMenuDidClose;
- (void)statusBarDidSelectAudioDeviceWithUID:(nullable NSString *)uid;
@end

@interface SPStatusBarManager : NSObject <NSMenuDelegate>

- (instancetype)initWithDelegate:(id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager;

/// Update the status bar icon and status text.
/// state: "idle", "recording_hold", "recording_toggle", "connecting_asr",
///        "finalizing_asr", "correcting", "preparing_paste", "pasting", "error", "completed"
- (void)updateState:(NSString *)state;

@end

#import <Cocoa/Cocoa.h>

@class SPPermissionManager;
@class SPHotkeyMonitor;
@class SPAudioCaptureManager;
@class SPAudioDeviceManager;
@class SPRustBridge;
@class SPClipboardManager;
@class SPPasteManager;
@class SPCuePlayer;
@class SPStatusBarManager;
@class SPHistoryManager;
@class SPOverlayPanel;

@interface SPAppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) SPPermissionManager *permissionManager;
@property (nonatomic, strong) SPHotkeyMonitor *hotkeyMonitor;
@property (nonatomic, strong) SPAudioCaptureManager *audioCaptureManager;
@property (nonatomic, strong) SPAudioDeviceManager *audioDeviceManager;
@property (nonatomic, strong) SPRustBridge *rustBridge;
@property (nonatomic, strong) SPClipboardManager *clipboardManager;
@property (nonatomic, strong) SPPasteManager *pasteManager;
@property (nonatomic, strong) SPCuePlayer *cuePlayer;
@property (nonatomic, strong) SPStatusBarManager *statusBarManager;
@property (nonatomic, strong) SPOverlayPanel *overlayPanel;
@property (nonatomic, strong) dispatch_source_t configWatcher;

@end

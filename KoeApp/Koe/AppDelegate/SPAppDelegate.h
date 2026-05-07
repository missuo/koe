#import <Cocoa/Cocoa.h>
#import "SPRustBridge.h"
#import "SPStatusBarManager.h"
#import "SPHotkeyMonitor.h"
#import "SPSetupWizardWindowController.h"

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
@class SPSetupWizardWindowController;
@class SPUpdateManager;

@interface SPAppDelegate : NSObject <NSApplicationDelegate, SPRustBridgeDelegate, SPStatusBarDelegate, SPHotkeyMonitorDelegate, SPSetupWizardDelegate>

/// Set to YES once the quit process has been initiated. Guards all
/// session, paste, and callback paths against late execution during
/// the run-loop draining that happens inside [NSApp terminate:].
@property (nonatomic, assign) BOOL quitting;

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
@property (nonatomic, strong) SPUpdateManager *updateManager;
@property (nonatomic, strong) dispatch_source_t configWatcher;
@property (nonatomic, strong) SPSetupWizardWindowController *setupWizard;
@property (nonatomic, copy) NSString *sessionState;
@property (nonatomic, assign) BOOL hasPendingConfigReload;

@end

#import <Cocoa/Cocoa.h>

@class SPRustBridge;

@protocol SPSetupWizardDelegate <NSObject>
@optional
/// Called after the wizard saves config, so the app can reload.
- (void)setupWizardDidSaveConfig;
@end

@interface SPSetupWizardWindowController : NSWindowController

@property (nonatomic, weak) id<SPSetupWizardDelegate> delegate;
@property (nonatomic, strong) SPRustBridge *rustBridge;

/// Show the wizard window (creates if needed, brings to front).
- (void)showWindow:(id)sender;

@end

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SPSessionModeObjC) {
    SPSessionModeHold = 0,
    SPSessionModeToggle = 1,
};

/// Delegate protocol for Rust core callbacks
@protocol SPRustBridgeDelegate <NSObject>
- (void)rustBridgeDidBecomeReady;
- (void)rustBridgeDidReceiveFinalText:(NSString *)text;
- (void)rustBridgeDidEncounterError:(NSString *)message;
- (void)rustBridgeDidReceiveWarning:(NSString *)message;
- (void)rustBridgeDidChangeState:(NSString *)state;
@end

@interface SPRustBridge : NSObject

- (instancetype)initWithDelegate:(id<SPRustBridgeDelegate>)delegate;

/// Initialize the Rust core library.
- (void)initializeCore;

/// Shut down the Rust core library.
- (void)destroyCore;

/// Begin a new voice input session.
- (void)beginSessionWithMode:(SPSessionModeObjC)mode;

/// Push an audio frame to the Rust core.
- (void)pushAudioFrame:(const void *)buffer length:(uint32_t)length timestamp:(uint64_t)timestamp;

/// End the current session.
- (void)endSession;

/// Reload configuration.
- (void)reloadConfig;

@end

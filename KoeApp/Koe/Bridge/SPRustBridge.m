#import "SPRustBridge.h"
#import <AppKit/AppKit.h>
#import "koe_core.h"

// ─── Static delegate reference for C callbacks ─────────────────────

static __weak id<SPRustBridgeDelegate> _bridgeDelegate = nil;

static void bridge_on_session_ready(void) {
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rustBridgeDidBecomeReady];
        });
    }
}

static void bridge_on_session_error(const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"unknown error";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rustBridgeDidEncounterError:msg];
        });
    }
}

static void bridge_on_session_warning(const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"unknown warning";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rustBridgeDidReceiveWarning:msg];
        });
    }
}

static void bridge_on_final_text_ready(const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rustBridgeDidReceiveFinalText:txt];
        });
    }
}

static void bridge_on_log_event(int level, const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"";
    NSString *levelStr;
    switch (level) {
        case 0: levelStr = @"ERROR"; break;
        case 1: levelStr = @"WARN"; break;
        case 2: levelStr = @"INFO"; break;
        default: levelStr = @"DEBUG"; break;
    }
    NSLog(@"[Koe/Rust][%@] %@", levelStr, msg);
}

static void bridge_on_state_changed(const char *state) {
    NSString *stateStr = state ? [NSString stringWithUTF8String:state] : @"unknown";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rustBridgeDidChangeState:stateStr];
        });
    }
}

// ─── SPRustBridge Implementation ────────────────────────────────────

@interface SPRustBridge ()
@property (nonatomic, weak) id<SPRustBridgeDelegate> delegate;
@end

@implementation SPRustBridge

- (instancetype)initWithDelegate:(id<SPRustBridgeDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _bridgeDelegate = delegate;
    }
    return self;
}

- (void)initializeCore {
    // Register callbacks
    struct SPCallbacks callbacks = {
        .on_session_ready = bridge_on_session_ready,
        .on_session_error = bridge_on_session_error,
        .on_session_warning = bridge_on_session_warning,
        .on_final_text_ready = bridge_on_final_text_ready,
        .on_log_event = bridge_on_log_event,
        .on_state_changed = bridge_on_state_changed,
    };
    sp_core_register_callbacks(callbacks);

    // Initialize core (config path unused in Phase 1)
    int32_t result = sp_core_create(NULL);
    if (result != 0) {
        NSLog(@"[Koe] sp_core_create failed: %d", result);
    }
}

- (void)destroyCore {
    sp_core_destroy();
}

- (void)beginSessionWithMode:(SPSessionModeObjC)mode {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    const char *bundleId = frontApp.bundleIdentifier.UTF8String;
    pid_t pid = frontApp.processIdentifier;

    struct SPSessionContext context = {
        .mode = (enum SPSessionMode)mode,
        .frontmost_bundle_id = bundleId,
        .frontmost_pid = (int)pid,
    };

    int32_t result = sp_core_session_begin(context);
    if (result != 0) {
        NSLog(@"[Koe] sp_core_session_begin failed: %d", result);
    }
}

- (void)pushAudioFrame:(const void *)buffer length:(uint32_t)length timestamp:(uint64_t)timestamp {
    sp_core_push_audio((const uint8_t *)buffer, length, timestamp);
}

- (void)endSession {
    sp_core_session_end();
}

- (void)reloadConfig {
    sp_core_reload_config();
}

@end

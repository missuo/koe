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
- (void)rustBridgeDidReceiveInterimText:(NSString *)text;
- (void)rustBridgeDidReceiveAsrFinalText:(NSString *)text;
- (void)rustBridgeDidReceiveRewriteText:(NSString *)text;
@end

@interface SPRustBridge : NSObject

/// Monotonic token identifying the current session.
/// Use this to guard delayed blocks against stale execution.
@property (nonatomic, readonly) uint64_t currentSessionToken;

- (instancetype)initWithDelegate:(id<SPRustBridgeDelegate>)delegate;

/// Initialize the Rust core library.
- (void)initializeCore;

/// Shut down the Rust core library.
- (void)destroyCore;

/// Begin a new voice input session. Returns YES on success.
- (BOOL)beginSessionWithMode:(SPSessionModeObjC)mode llmInverted:(BOOL)llmInverted;

/// Push an audio frame to the Rust core.
- (void)pushAudioFrame:(const void *)buffer length:(uint32_t)length timestamp:(uint64_t)timestamp;

/// End the current session.
- (void)endSession;

/// Cancel the current session (no text output).
- (void)cancelSession;

/// Reload configuration.
- (void)reloadConfig;

// ─── Model Management ──────────────────────────────────────────────

/// Return supported local provider names (e.g. @[@"mlx", @"sherpa-onnx"]).
- (NSArray<NSString *> *)supportedLocalProviders;

/// Return supported LLM provider names (e.g. @[@"openai", @"mlx"]).
- (NSArray<NSString *> *)supportedLlmProviders;

/// Fetch remote model IDs from an OpenAI-compatible `{base_url}/models` endpoint.
/// Returns dictionary: { success: BOOL, models: NSArray<NSString *>, message: NSString }
- (NSDictionary *)llmRemoteModelsForBaseURL:(NSString *)baseURL apiKey:(NSString *)apiKey;

/// Scan all models and return array of dictionaries.
/// Each dict: path, provider, description, repo, total_size, status (0/1/2)
- (NSArray<NSDictionary *> *)scanModels;

typedef NS_ENUM(NSInteger, SPModelVerifyMode) {
    SPModelVerifyNormal = 0,      // cached sha256, compute on miss
    SPModelVerifyCacheOnly = 1,   // cache hit only, no compute
    SPModelVerifyForce = 2,       // ignore cache, always compute
};

/// Model status with configurable verification: 0=not installed, 1=incomplete, 2=installed
- (NSInteger)modelStatus:(NSString *)modelPath mode:(SPModelVerifyMode)mode;

/// Download a model asynchronously.
- (void)downloadModel:(NSString *)modelPath
             progress:(void (^)(NSUInteger fileIndex, NSUInteger fileCount,
                                uint64_t downloaded, uint64_t total,
                                NSString *filename))progressBlock
           completion:(void (^)(BOOL success, NSString *message))completionBlock;

/// Cancel an active download.
- (void)cancelDownload:(NSString *)modelPath;

// ─── Rewrite / Prompt Templates ───────────────────────────────────

/// Get prompt templates as array of dicts mirroring PromptTemplate in Rust config.
- (NSArray<NSDictionary *> *)promptTemplates;

/// Save prompt templates from array of dicts. Returns YES on success.
- (BOOL)setPromptTemplates:(NSArray<NSDictionary *> *)templates;

/// Rewrite ASR text using template at given index. Returns YES on success.
- (BOOL)rewriteWithTemplateIndex:(NSInteger)index asrText:(NSString *)text;

/// Remove downloaded model files (keeps manifest). Returns files removed.
- (NSInteger)removeModelFiles:(NSString *)modelPath;

@end

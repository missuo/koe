#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

/// Callback invoked for each captured audio frame.
/// buffer: pointer to PCM Int16 LE data
/// length: byte length of the buffer
/// timestamp: host time in nanoseconds
typedef void (^SPAudioFrameCallback)(const void *buffer, uint32_t length, uint64_t timestamp);

@interface SPAudioCaptureManager : NSObject

/// Set the input device used when preparing the next queue.
/// Pass kAudioObjectUnknown (0) to use the system default input device.
- (void)setInputDeviceID:(AudioDeviceID)deviceID;

/// Whether to mute the system default output device while capturing.
/// Must be set BEFORE startCaptureWithAudioCallback:includePreRoll:. Default is NO.
@property (nonatomic, assign) BOOL muteOutputEnabled;

/// Create and configure the input queue without starting audio hardware.
/// This moves allocation and device setup off the hotkey path while leaving
/// the microphone privacy indicator off.
- (BOOL)prepare;

/// Start the prepared input queue as soon as the trigger goes down and retain
/// a short PCM pre-roll until the hotkey gesture is confirmed.
- (BOOL)beginPreCapture;

/// Cancel an unconfirmed pre-capture and return to a prepared, inactive queue.
- (void)cancelPreCapture;

/// Arm a confirmed capture session. Any PCM collected since trigger-down is
/// delivered first, followed by live audio.
/// Audio format: 16kHz, mono, PCM Int16 LE, ~200ms per frame.
- (BOOL)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback
                       includePreRoll:(BOOL)includePreRoll;

/// Stop a confirmed capture and prepare a fresh inactive queue for next time.
/// Also restores system output if this manager muted it.
- (void)stopCapture;

/// Stop and dispose all audio resources without preparing another queue.
/// Also restores system output if this manager muted it.
- (void)shutdown;

/// Restore system output mute if this manager previously muted it.
/// Safe to call when not capturing; used as a terminate safety net.
- (void)restoreMutedSystemOutputIfNeeded;

/// Log an app-level activation milestone against the current trigger-down
/// using the same monotonic clock and activation sequence as queue metrics.
- (void)logActivationMilestone:(NSString *)milestone;
- (void)logActivationMilestone:(NSString *)milestone
          forActivationSequence:(NSUInteger)activationSequence;

@property (nonatomic, readonly) BOOL isCapturing;
@property (nonatomic, readonly) BOOL isPreCapturing;
@property (nonatomic, readonly) BOOL isAudioQueueRunning;
@property (nonatomic, readonly) NSUInteger activationSequence;

@end

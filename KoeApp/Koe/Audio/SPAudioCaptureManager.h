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
- (void)stopCapture;

/// Stop and dispose all audio resources without preparing another queue.
- (void)shutdown;

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

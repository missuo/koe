#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

/// Callback invoked for each captured audio frame.
/// buffer: pointer to PCM Int16 LE data
/// length: byte length of the buffer
/// timestamp: host time in nanoseconds
typedef void (^SPAudioFrameCallback)(const void *buffer, uint32_t length, uint64_t timestamp);

@interface SPAudioCaptureManager : NSObject

/// Set the input device for the next capture session.
/// Must be called BEFORE startCaptureWithAudioCallback:.
/// Pass kAudioObjectUnknown (0) to use the system default input device.
- (void)setInputDeviceID:(AudioDeviceID)deviceID;

/// Start audio capture. Captured frames are delivered via the callback.
/// Audio format: 16kHz, mono, PCM Int16 LE, ~200ms per frame (3200 samples).
- (void)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback;

/// Stop audio capture.
- (void)stopCapture;

@property (nonatomic, readonly) BOOL isCapturing;

@end

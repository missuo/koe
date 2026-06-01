#import "SPAudioCaptureManager.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// ASR recommends 200ms frames for best performance with bigmodel
static const NSUInteger kTargetSampleRate = 16000;
static const NSUInteger kFrameSamples = 3200; // 200ms at 16kHz

// Maximum time to wait for AVAudioEngine.start() before giving up.
// This timeout now runs off the main thread, so a HAL/CoreAudio stall cannot
// freeze the menu bar UI.
static const NSTimeInterval kEngineStartTimeoutSec = 3.0;

@interface SPAudioCaptureManager ()

@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, copy) SPAudioFrameCallback audioCallback;
@property (nonatomic, readwrite) BOOL isCapturing;
@property (nonatomic, assign) BOOL isStarting;
@property (nonatomic, assign) uint64_t startGeneration;
@property (nonatomic, strong) NSMutableData *accumBuffer;
@property (nonatomic, assign) AudioDeviceID pendingDeviceID;

@end

@implementation SPAudioCaptureManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCapturing = NO;
        _isStarting = NO;
        _startGeneration = 0;
        _accumBuffer = [NSMutableData data];
        _pendingDeviceID = kAudioObjectUnknown;
    }
    return self;
}

- (BOOL)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback {
    if (!callback) return NO;

    // Keep the legacy synchronous API for callers that still expect it. The
    // AppDelegate uses the asynchronous API so the main run loop stays fluid.
    if ([NSThread isMainThread]) {
        if (self.isCapturing || self.isStarting) return NO;

        self.isStarting = YES;
        self.startGeneration++;
        NSMutableData *accumBuffer = [NSMutableData data];
        AVAudioEngine *engine = [self startedAudioEngineWithDeviceID:self.pendingDeviceID
                                                            callback:[callback copy]
                                                         accumBuffer:accumBuffer];
        self.isStarting = NO;
        if (!engine) return NO;

        self.audioEngine = engine;
        self.audioCallback = [callback copy];
        self.accumBuffer = accumBuffer;
        self.isCapturing = YES;
        NSLog(@"[Koe] Audio capture started (hardware -> 16kHz mono, 200ms frames)");
        return YES;
    }

    __block BOOL started = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self startCaptureWithAudioCallback:callback completion:^(BOOL ok) {
        started = ok;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return started;
}

- (void)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback
                           completion:(SPAudioCaptureStartCompletion)completion {
    SPAudioCaptureStartCompletion completionCopy = completion ? [completion copy] : [^(BOOL started) {} copy];
    SPAudioFrameCallback callbackCopy = [callback copy];
    if (!callbackCopy) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(NO);
        });
        return;
    }

    void (^beginStart)(void) = ^{
        if (self.isCapturing || self.isStarting) {
            completionCopy(NO);
            return;
        }

        self.isStarting = YES;
        self.startGeneration++;
        uint64_t generation = self.startGeneration;
        AudioDeviceID deviceID = self.pendingDeviceID;
        NSMutableData *accumBuffer = [NSMutableData data];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            AVAudioEngine *engine = [self startedAudioEngineWithDeviceID:deviceID
                                                                callback:callbackCopy
                                                             accumBuffer:accumBuffer];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.startGeneration || !self.isStarting) {
                    if (engine) {
                        [engine.inputNode removeTapOnBus:0];
                        [engine stop];
                    }
                    completionCopy(NO);
                    return;
                }

                self.isStarting = NO;
                if (!engine) {
                    completionCopy(NO);
                    return;
                }

                self.audioEngine = engine;
                self.audioCallback = callbackCopy;
                self.accumBuffer = accumBuffer;
                self.isCapturing = YES;
                NSLog(@"[Koe] Audio capture started (hardware -> 16kHz mono, 200ms frames)");
                completionCopy(YES);
            });
        });
    };

    if ([NSThread isMainThread]) {
        beginStart();
    } else {
        dispatch_async(dispatch_get_main_queue(), beginStart);
    }
}

- (AVAudioEngine *)startedAudioEngineWithDeviceID:(AudioDeviceID)deviceID
                                         callback:(SPAudioFrameCallback)callback
                                      accumBuffer:(NSMutableData *)accumBuffer {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = engine.inputNode;

    // Set input device if specified (must be before querying hardware format).
    // If this fails (e.g. BT device route changed, error 'nope'/1852797029),
    // abandon this engine entirely. The IO unit may be inconsistent, and
    // proceeding can cause startAndReturnError: to block.
    if (deviceID != kAudioObjectUnknown) {
        OSStatus osStatus = AudioUnitSetProperty(inputNode.audioUnit,
                                                  kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0,
                                                  &deviceID, sizeof(deviceID));
        if (osStatus != noErr) {
            NSLog(@"[Koe] Failed to set input device (ID %u): OSStatus %d; falling back to system default",
                  (unsigned)deviceID, (int)osStatus);
            engine = [[AVAudioEngine alloc] init];
            inputNode = engine.inputNode;
        } else {
            NSLog(@"[Koe] Input device set to ID %u", (unsigned)deviceID);
        }
    }

    AVAudioFormat *hardwareFormat = [inputNode outputFormatForBus:0];
    NSLog(@"[Koe] Hardware audio format: %@", hardwareFormat);

    if (hardwareFormat.channelCount == 0 || hardwareFormat.sampleRate <= 0) {
        NSLog(@"[Koe] ERROR: inputNode format invalid (channels=%u sampleRate=%.0f); microphone may not be ready yet",
              hardwareFormat.channelCount, hardwareFormat.sampleRate);
        return nil;
    }

    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:kTargetSampleRate
                                                                    channels:1
                                                                 interleaved:NO];

    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:hardwareFormat
                                                                 toFormat:targetFormat];
    if (!converter) {
        NSLog(@"[Koe] ERROR: Failed to create audio converter from %@ to %@", hardwareFormat, targetFormat);
        return nil;
    }

    const NSUInteger targetByteLength = kFrameSamples * sizeof(int16_t);
    double sampleRateRatio = kTargetSampleRate / hardwareFormat.sampleRate;
    __weak typeof(self) weakSelf = self;

    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:hardwareFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !callback) return;

        AVAudioFrameCount outputFrames = (AVAudioFrameCount)(buffer.frameLength * sampleRateRatio) + 1;
        AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat
                                                                          frameCapacity:outputFrames];

        NSError *convError = nil;
        __block BOOL inputProvided = NO;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:convertedBuffer
                                                                  error:&convError
                                               withInputFromBlock:^AVAudioBuffer *(AVAudioFrameCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
            if (inputProvided) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            inputProvided = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        }];

        if (status == AVAudioConverterOutputStatus_Error) {
            NSLog(@"[Koe] Audio conversion error: %@", convError);
            return;
        }

        if (convertedBuffer.frameLength == 0) return;

        float *floatData = convertedBuffer.floatChannelData[0];
        AVAudioFrameCount frameCount = convertedBuffer.frameLength;
        NSUInteger byteCount = frameCount * sizeof(int16_t);
        int16_t *int16Data = (int16_t *)malloc(byteCount);
        if (!int16Data) return;

        for (AVAudioFrameCount i = 0; i < frameCount; i++) {
            float sample = floatData[i];
            if (sample > 1.0f) sample = 1.0f;
            if (sample < -1.0f) sample = -1.0f;
            int16Data[i] = (int16_t)(sample * 32767.0f);
        }

        @synchronized (accumBuffer) {
            [accumBuffer appendBytes:int16Data length:byteCount];
            free(int16Data);

            while (accumBuffer.length >= targetByteLength) {
                uint64_t timestamp = mach_absolute_time();
                callback(accumBuffer.bytes, (uint32_t)targetByteLength, timestamp);
                [accumBuffer replaceBytesInRange:NSMakeRange(0, targetByteLength) withBytes:NULL length:0];
            }
        }
    }];

    [engine prepare];

    __block BOOL startOK = NO;
    __block NSError *startError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *bgError = nil;
        startOK = [engine startAndReturnError:&bgError];
        startError = bgError;
        dispatch_semaphore_signal(sem);
    });

    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(kEngineStartTimeoutSec * NSEC_PER_SEC)));
    if (timedOut != 0) {
        NSLog(@"[Koe] Audio engine start timed out after %.0fs; aborting without blocking UI",
              kEngineStartTimeoutSec);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [engine stop];
        });
        return nil;
    }

    if (!startOK) {
        NSLog(@"[Koe] Audio engine start failed: %@", startError.localizedDescription ?: @"unknown error");
        [inputNode removeTapOnBus:0];
        return nil;
    }

    return engine;
}

- (void)setInputDeviceID:(AudioDeviceID)deviceID {
    self.pendingDeviceID = deviceID;
}

- (void)stopCapture {
    // Invalidate any asynchronous start that has not been accepted yet.
    self.startGeneration++;
    self.isStarting = NO;

    if (!self.isCapturing) return;

    AVAudioEngine *engine = self.audioEngine;
    NSMutableData *accumBuffer = self.accumBuffer;
    SPAudioFrameCallback callback = self.audioCallback;

    self.audioEngine = nil;
    self.audioCallback = nil;
    self.accumBuffer = [NSMutableData data];
    self.isCapturing = NO;

    [engine.inputNode removeTapOnBus:0];
    [engine stop];

    @synchronized (accumBuffer) {
        if (accumBuffer.length > 0 && callback) {
            NSLog(@"[Koe] Flushing remaining %lu bytes of audio", (unsigned long)accumBuffer.length);
            uint64_t timestamp = mach_absolute_time();
            callback(accumBuffer.bytes, (uint32_t)accumBuffer.length, timestamp);
            [accumBuffer setLength:0];
        }
    }

    NSLog(@"[Koe] Audio capture stopped");
}

@end

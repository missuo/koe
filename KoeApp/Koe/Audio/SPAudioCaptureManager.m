#import "SPAudioCaptureManager.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// ASR recommends 200ms frames for best performance with bigmodel
static const NSUInteger kTargetSampleRate = 16000;
static const NSUInteger kFrameSamples = 3200; // 200ms at 16kHz

// Maximum time to wait for AVAudioEngine.start() before giving up.
// Prevents indefinite main-thread hang when CoreAudio's HAL proxy
// blocks in StartAndWaitForState after a device route change.
static const NSTimeInterval kEngineStartTimeoutSec = 3.0;

@interface SPAudioCaptureManager ()

@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, copy) SPAudioFrameCallback audioCallback;
@property (nonatomic, readwrite) BOOL isCapturing;
@property (nonatomic, strong) NSMutableData *accumBuffer;
@property (nonatomic, assign) AudioDeviceID pendingDeviceID;

@end

@implementation SPAudioCaptureManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCapturing = NO;
        _accumBuffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback {
    if (self.isCapturing) return NO;

    self.audioCallback = callback;
    [self.accumBuffer setLength:0];

    // Create a fresh engine each session so stale device state (e.g. after
    // Bluetooth reconnect) never carries over from a previous capture.
    self.audioEngine = [[AVAudioEngine alloc] init];

    AVAudioInputNode *inputNode = self.audioEngine.inputNode;

    // Set input device if specified (must be before querying hardware format).
    // If this fails (e.g. BT device route changed, error 'nope'/1852797029),
    // abandon this engine entirely — the IO unit is in an inconsistent state
    // and proceeding would cause startAndReturnError: to block indefinitely.
    if (self.pendingDeviceID != kAudioObjectUnknown) {
        AudioDeviceID deviceID = self.pendingDeviceID;
        OSStatus osStatus = AudioUnitSetProperty(inputNode.audioUnit,
                                                  kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0,
                                                  &deviceID, sizeof(deviceID));
        if (osStatus != noErr) {
            NSLog(@"[Koe] Failed to set input device (ID %u): OSStatus %d — "
                  "falling back to a new engine with system default",
                  (unsigned)deviceID, (int)osStatus);
            self.audioEngine = [[AVAudioEngine alloc] init];
            inputNode = self.audioEngine.inputNode;
        } else {
            NSLog(@"[Koe] Input device set to ID %u", (unsigned)deviceID);
        }
    }

    // Use the hardware's native format for the tap — cannot request a different sample rate
    AVAudioFormat *hardwareFormat = [inputNode outputFormatForBus:0];
    NSLog(@"[Koe] Hardware audio format: %@", hardwareFormat);

    // Guard against invalid inputNode state. After a Bluetooth device route
    // change or a fresh mic permission grant, the node may report 0 channels
    // or 0 sampleRate. Proceeding would cause audioEngine.start() to block
    // or throw -10877 (kAudioUnitErr_InvalidElement).
    if (hardwareFormat.channelCount == 0 || hardwareFormat.sampleRate <= 0) {
        NSLog(@"[Koe] ERROR: inputNode format invalid (channels=%u sampleRate=%.0f) — "
              "microphone may not be ready yet",
              hardwareFormat.channelCount, hardwareFormat.sampleRate);
        self.audioEngine = nil;
        return NO;
    }

    // Target format: 16kHz, mono, Float32 for conversion
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:kTargetSampleRate
                                                                    channels:1
                                                                 interleaved:NO];

    // Create converter from hardware format to 16kHz mono
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:hardwareFormat
                                                                 toFormat:targetFormat];
    if (!converter) {
        NSLog(@"[Koe] ERROR: Failed to create audio converter from %@ to %@", hardwareFormat, targetFormat);
        self.audioEngine = nil;
        return NO;
    }

    const NSUInteger targetByteLength = kFrameSamples * sizeof(int16_t); // 6400 bytes per 200ms
    double sampleRateRatio = kTargetSampleRate / hardwareFormat.sampleRate;

    __weak typeof(self) weakSelf = self;

    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:hardwareFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.audioCallback) return;

        // Estimate output frame count
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

        // Convert Float32 -> Int16 LE
        float *floatData = convertedBuffer.floatChannelData[0];
        AVAudioFrameCount frameCount = convertedBuffer.frameLength;
        NSUInteger byteCount = frameCount * sizeof(int16_t);
        int16_t *int16Data = (int16_t *)malloc(byteCount);

        for (AVAudioFrameCount i = 0; i < frameCount; i++) {
            float sample = floatData[i];
            if (sample > 1.0f) sample = 1.0f;
            if (sample < -1.0f) sample = -1.0f;
            int16Data[i] = (int16_t)(sample * 32767.0f);
        }

        // Accumulate into 200ms frames
        @synchronized (strongSelf.accumBuffer) {
            [strongSelf.accumBuffer appendBytes:int16Data length:byteCount];
            free(int16Data);

            while (strongSelf.accumBuffer.length >= targetByteLength) {
                uint64_t timestamp = mach_absolute_time();
                strongSelf.audioCallback(strongSelf.accumBuffer.bytes, (uint32_t)targetByteLength, timestamp);
                [strongSelf.accumBuffer replaceBytesInRange:NSMakeRange(0, targetByteLength) withBytes:NULL length:0];
            }
        }
    }];

    // Start the engine off the main thread with a timeout to prevent the
    // main-thread hang reported in missuo/koe#77: after a Bluetooth device
    // route change, HALC_ProxyIOContext::StartAndWaitForState can block
    // indefinitely (error 35 / EAGAIN), freezing the entire app.
    [self.audioEngine prepare];

    __block BOOL startOK = NO;
    __block NSError *startError = nil;
    AVAudioEngine *engine = self.audioEngine;
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
        NSLog(@"[Koe] Audio engine start timed out after %.0fs — "
              "aborting to prevent main-thread hang", kEngineStartTimeoutSec);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [engine stop];
        });
        self.audioEngine = nil;
        return NO;
    }

    if (!startOK) {
        NSLog(@"[Koe] Audio engine start failed: %@", startError.localizedDescription ?: @"unknown error");
        self.audioEngine = nil;
        return NO;
    }

    self.isCapturing = YES;
    NSLog(@"[Koe] Audio capture started (hardware -> 16kHz mono, 200ms frames)");
    return YES;
}

- (void)setInputDeviceID:(AudioDeviceID)deviceID {
    self.pendingDeviceID = deviceID;
}

- (void)stopCapture {
    if (!self.isCapturing) return;

    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine stop];

    // Flush remaining audio in the accumulation buffer — this prevents
    // the last few words from being cut off when the user releases Fn
    @synchronized (self.accumBuffer) {
        if (self.accumBuffer.length > 0 && self.audioCallback) {
            NSLog(@"[Koe] Flushing remaining %lu bytes of audio", (unsigned long)self.accumBuffer.length);
            uint64_t timestamp = mach_absolute_time();
            self.audioCallback(self.accumBuffer.bytes, (uint32_t)self.accumBuffer.length, timestamp);
            [self.accumBuffer setLength:0];
        }
    }

    self.audioCallback = nil;
    self.isCapturing = NO;
    self.audioEngine = nil;
    NSLog(@"[Koe] Audio capture stopped");
}

@end

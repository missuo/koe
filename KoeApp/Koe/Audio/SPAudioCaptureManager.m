#import "SPAudioCaptureManager.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// ASR recommends 200ms frames for best performance with bigmodel
static const NSUInteger kTargetSampleRate = 16000;
static const NSUInteger kFrameSamples = 3200; // 200ms at 16kHz

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

    // Set input device if specified (must be before querying hardware format)
    if (self.pendingDeviceID != kAudioObjectUnknown) {
        AudioDeviceID deviceID = self.pendingDeviceID;
        OSStatus osStatus = AudioUnitSetProperty(inputNode.audioUnit,
                                                  kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0,
                                                  &deviceID, sizeof(deviceID));
        if (osStatus != noErr) {
            NSLog(@"[Koe] Failed to set input device (ID %u): %d, using default",
                  (unsigned)deviceID, (int)osStatus);
        } else {
            NSLog(@"[Koe] Input device set to ID %u", (unsigned)deviceID);
        }
    }

    // Use the hardware's native format for the tap — cannot request a different sample rate
    AVAudioFormat *hardwareFormat = [inputNode outputFormatForBus:0];
    NSLog(@"[Koe] Hardware audio format: %@", hardwareFormat);

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

    NSError *error = nil;
    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) {
        NSLog(@"[Koe] Audio engine start failed: %@", error.localizedDescription ?: @"unknown error");
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
    NSLog(@"[Koe] Audio capture stopped");
}

@end

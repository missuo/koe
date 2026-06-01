#import "SPAudioCaptureManager.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <mach/mach_time.h>

// ASR recommends 200ms frames for best performance with bigmodel
static const double kTargetSampleRate = 16000.0;
static const NSUInteger kFrameSamples = 3200; // 200ms at 16kHz

// 3 buffers × 50ms each — enough to absorb scheduling jitter without latency
static const int kNumBuffers = 3;
static const UInt32 kBufferFrames = 800; // 50ms at 16kHz

@interface SPAudioCaptureManager ()

@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, copy) SPAudioFrameCallback audioCallback;
@property (nonatomic, readwrite) BOOL isCapturing;
@property (nonatomic, strong) NSMutableData *accumBuffer;
@property (nonatomic, assign) AudioDeviceID pendingDeviceID;

@end

// ---------------------------------------------------------------------------
// AudioQueue callback — runs on an AudioQueue internal thread
// ---------------------------------------------------------------------------

static void queueInputCallback(void *userData,
                               AudioQueueRef queue,
                               AudioQueueBufferRef buffer,
                               const AudioTimeStamp *startTime,
                               UInt32 numPackets,
                               const AudioStreamPacketDescription *packetDesc) {
    SPAudioCaptureManager *manager = (__bridge SPAudioCaptureManager *)userData;
    if (!manager.isCapturing || !manager.audioCallback || numPackets == 0) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        return;
    }

    // Convert Float32 -> Int16 LE
    float *floatSamples = (float *)buffer->mAudioData;
    UInt32 frameCount = buffer->mAudioDataByteSize / sizeof(float);
    NSUInteger byteCount = frameCount * sizeof(int16_t);
    int16_t *pcm = (int16_t *)malloc(byteCount);

    for (UInt32 i = 0; i < frameCount; i++) {
        float s = floatSamples[i];
        s = s > 1.0f ? 1.0f : (s < -1.0f ? -1.0f : s);
        pcm[i] = (int16_t)(s * 32767.0f);
    }

    // Accumulate into 200ms frames
    const NSUInteger frameByteLen = kFrameSamples * sizeof(int16_t);
    @synchronized (manager.accumBuffer) {
        [manager.accumBuffer appendBytes:pcm length:byteCount];
        free(pcm);

        while (manager.accumBuffer.length >= frameByteLen) {
            uint64_t ts = mach_absolute_time();
            manager.audioCallback(manager.accumBuffer.bytes, (uint32_t)frameByteLen, ts);
            [manager.accumBuffer replaceBytesInRange:NSMakeRange(0, frameByteLen)
                                          withBytes:NULL length:0];
        }
    }

    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

// ---------------------------------------------------------------------------

@implementation SPAudioCaptureManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCapturing = NO;
        _accumBuffer = [NSMutableData data];
        _pendingDeviceID = kAudioObjectUnknown;
    }
    return self;
}

- (void)setInputDeviceID:(AudioDeviceID)deviceID {
    self.pendingDeviceID = deviceID;
}

- (BOOL)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback {
    if (self.isCapturing) return NO;

    self.audioCallback = callback;
    [self.accumBuffer setLength:0];

    // Request 16kHz mono Float32 directly. AudioQueue handles resampling from
    // the hardware's native rate internally and is input-only — it never binds
    // to the output device. This avoids the aggregate-device / channel-layout
    // error (-10877) that AVAudioEngine triggers when the input and output
    // devices run at different sample rates (e.g. mic 44100 vs speaker 48000).
    AudioStreamBasicDescription fmt = {
        .mSampleRate       = kTargetSampleRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBitsPerChannel   = 32,
        .mChannelsPerFrame = 1,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = sizeof(float),
        .mBytesPerPacket   = sizeof(float),
    };

    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewInput(&fmt, queueInputCallback,
                                         (__bridge void *)self,
                                         NULL, NULL, 0, &queue);
    if (status != noErr) {
        NSLog(@"[Koe] Failed to create audio queue: %d", (int)status);
        return NO;
    }

    // Select input device if specified. AudioQueue uses device UID (CFStringRef),
    // so convert from AudioDeviceID.
    if (self.pendingDeviceID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress uidAddr = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        OSStatus uidStatus = AudioObjectGetPropertyData(self.pendingDeviceID, &uidAddr,
                                                        0, NULL, &uidSize, &uid);
        if (uidStatus == noErr && uid) {
            OSStatus setStatus = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice,
                                                       &uid, sizeof(CFStringRef));
            if (setStatus != noErr) {
                NSLog(@"[Koe] Failed to set input device (ID %u): %d — using system default",
                      (unsigned)self.pendingDeviceID, (int)setStatus);
            } else {
                NSLog(@"[Koe] Input device set to ID %u", (unsigned)self.pendingDeviceID);
            }
            CFRelease(uid);
        }
    }

    // Allocate and enqueue buffers
    UInt32 bufferSize = kBufferFrames * sizeof(float);
    for (int i = 0; i < kNumBuffers; i++) {
        AudioQueueBufferRef buf;
        status = AudioQueueAllocateBuffer(queue, bufferSize, &buf);
        if (status != noErr) {
            NSLog(@"[Koe] Failed to allocate audio queue buffer %d: %d", i, (int)status);
            AudioQueueDispose(queue, true);
            return NO;
        }
        AudioQueueEnqueueBuffer(queue, buf, 0, NULL);
    }

    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        NSLog(@"[Koe] Audio queue start failed: %d", (int)status);
        AudioQueueDispose(queue, true);
        return NO;
    }

    self.audioQueue = queue;
    self.isCapturing = YES;
    NSLog(@"[Koe] Audio capture started (AudioQueue 16kHz mono Float32, 200ms frames)");
    return YES;
}

- (void)stopCapture {
    if (!self.isCapturing) return;

    self.isCapturing = NO;

    // Flush remaining audio — prevents the last words from being cut off
    // when the user releases the hotkey
    @synchronized (self.accumBuffer) {
        if (self.accumBuffer.length > 0 && self.audioCallback) {
            NSLog(@"[Koe] Flushing remaining %lu bytes of audio",
                  (unsigned long)self.accumBuffer.length);
            uint64_t ts = mach_absolute_time();
            self.audioCallback(self.accumBuffer.bytes, (uint32_t)self.accumBuffer.length, ts);
            [self.accumBuffer setLength:0];
        }
    }

    AudioQueueStop(self.audioQueue, true);
    AudioQueueDispose(self.audioQueue, true);
    self.audioQueue = NULL;
    self.audioCallback = nil;
    NSLog(@"[Koe] Audio capture stopped");
}

@end

#import "SPAudioCaptureManager.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <mach/mach_time.h>

// ASR recommends 200ms frames for best performance with bigmodel.
static const double kTargetSampleRate = 16000.0;
static const NSUInteger kFrameSamples = 3200; // 200ms at 16kHz

// Retain enough trigger-down audio to cover the hotkey decision window and a
// Bluetooth input route transition without losing the user's first word.
static const NSUInteger kMaxPreRollSamples = 4800; // 300ms at 16kHz

// 3 buffers x 50ms each — enough to absorb scheduling jitter without latency.
static const int kNumBuffers = 3;
static const UInt32 kBufferFrames = 800; // 50ms at 16kHz

@interface SPAudioCaptureManager ()

@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, copy) SPAudioFrameCallback audioCallback;
@property (nonatomic, readwrite) BOOL isCapturing;
@property (nonatomic, readwrite) BOOL isPreCapturing;
@property (nonatomic, readwrite) BOOL isAudioQueueRunning;
@property (nonatomic, strong) NSMutableData *accumBuffer;
@property (nonatomic, strong) NSMutableData *preRollBuffer;
@property (nonatomic, assign) AudioDeviceID pendingDeviceID;
@property (nonatomic, assign) AudioDeviceID preparedDeviceID;
@property (nonatomic, assign) uint64_t activationStartedHostTime;
@property (nonatomic, readwrite) NSUInteger activationSequence;
@property (nonatomic, assign) uint64_t previousActivationStartedHostTime;
@property (nonatomic, assign) NSUInteger previousActivationSequence;
@property (nonatomic, assign) BOOL waitingForFirstCallback;
@property (nonatomic, assign) BOOL waitingForFirstFrame;

- (BOOL)startPreparedQueue;
- (void)stopAndReprepare;
- (void)disposeQueue;

@end

static double elapsedMillisecondsSince(uint64_t startedAt) {
    if (startedAt == 0) return 0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t elapsed = mach_continuous_time() - startedAt;
    return ((double)elapsed * (double)timebase.numer / (double)timebase.denom) / 1.0e6;
}

static void queueRunningChanged(void *userData,
                                AudioQueueRef queue,
                                AudioQueuePropertyID propertyID) {
    SPAudioCaptureManager *manager = (__bridge SPAudioCaptureManager *)userData;
    UInt32 isRunning = 0;
    UInt32 size = sizeof(isRunning);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning,
                              &isRunning, &size) != noErr) {
        return;
    }
    double elapsedMs = elapsedMillisecondsSince(manager.activationStartedHostTime);
    NSLog(@"[Koe] Audio activation #%lu: queue IsRunning=%u at %.1fms",
          (unsigned long)manager.activationSequence, (unsigned)isRunning, elapsedMs);
}

static void appendPreRoll(SPAudioCaptureManager *manager,
                          const int16_t *pcm,
                          NSUInteger byteCount) {
    const NSUInteger maxBytes = kMaxPreRollSamples * sizeof(int16_t);
    [manager.preRollBuffer appendBytes:pcm length:byteCount];
    if (manager.preRollBuffer.length > maxBytes) {
        NSUInteger excess = manager.preRollBuffer.length - maxBytes;
        [manager.preRollBuffer replaceBytesInRange:NSMakeRange(0, excess)
                                         withBytes:NULL
                                            length:0];
    }
}

// AudioQueue callback — runs on an AudioQueue internal thread.
static void queueInputCallback(void *userData,
                               AudioQueueRef queue,
                               AudioQueueBufferRef buffer,
                               const AudioTimeStamp *startTime,
                               UInt32 numPackets,
                               const AudioStreamPacketDescription *packetDesc) {
    SPAudioCaptureManager *manager = (__bridge SPAudioCaptureManager *)userData;
    if (numPackets == 0) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        return;
    }

    float *floatSamples = (float *)buffer->mAudioData;
    UInt32 frameCount = buffer->mAudioDataByteSize / sizeof(float);
    NSUInteger byteCount = frameCount * sizeof(int16_t);
    int16_t *pcm = (int16_t *)malloc(byteCount);
    if (!pcm) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        return;
    }

    for (UInt32 i = 0; i < frameCount; i++) {
        float sample = floatSamples[i];
        sample = sample > 1.0f ? 1.0f : (sample < -1.0f ? -1.0f : sample);
        pcm[i] = (int16_t)(sample * 32767.0f);
    }

    const NSUInteger frameByteLen = kFrameSamples * sizeof(int16_t);
    @synchronized (manager.accumBuffer) {
        if (manager.waitingForFirstCallback) {
            manager.waitingForFirstCallback = NO;
            double elapsedMs = elapsedMillisecondsSince(manager.activationStartedHostTime);
            NSLog(@"[Koe] Audio activation #%lu: first callback at %.1fms",
                  (unsigned long)manager.activationSequence, elapsedMs);
        }
        if (manager.isPreCapturing) {
            appendPreRoll(manager, pcm, byteCount);
        }
        if (manager.isCapturing && manager.audioCallback) {
            [manager.accumBuffer appendBytes:pcm length:byteCount];
            while (manager.accumBuffer.length >= frameByteLen) {
                SPAudioFrameCallback callback = manager.audioCallback;
                uint64_t timestamp = mach_absolute_time();
                callback(manager.accumBuffer.bytes, (uint32_t)frameByteLen, timestamp);
                if (manager.waitingForFirstFrame) {
                    manager.waitingForFirstFrame = NO;
                    double elapsedMs = elapsedMillisecondsSince(manager.activationStartedHostTime);
                    NSLog(@"[Koe] Audio activation #%lu: first 200ms frame at %.1fms",
                          (unsigned long)manager.activationSequence, elapsedMs);
                }
                [manager.accumBuffer replaceBytesInRange:NSMakeRange(0, frameByteLen)
                                               withBytes:NULL
                                                  length:0];
            }
        }
    }

    free(pcm);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

@implementation SPAudioCaptureManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _accumBuffer = [NSMutableData data];
        _preRollBuffer = [NSMutableData data];
        _pendingDeviceID = kAudioObjectUnknown;
        _preparedDeviceID = kAudioObjectUnknown;
    }
    return self;
}

- (void)setInputDeviceID:(AudioDeviceID)deviceID {
    if (self.pendingDeviceID == deviceID) return;
    self.pendingDeviceID = deviceID;
    if (self.audioQueue && !self.isAudioQueueRunning && self.preparedDeviceID != deviceID) {
        [self disposeQueue];
    }
}

- (BOOL)prepare {
    if (self.audioQueue) return YES;

    uint64_t prepareStartedAt = mach_continuous_time();

    AudioStreamBasicDescription format = {
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
    OSStatus status = AudioQueueNewInput(&format, queueInputCallback,
                                         (__bridge void *)self,
                                         NULL, NULL, 0, &queue);
    if (status != noErr) {
        NSLog(@"[Koe] Failed to prepare audio queue: %d", (int)status);
        return NO;
    }

    if (self.pendingDeviceID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        OSStatus uidStatus = AudioObjectGetPropertyData(self.pendingDeviceID,
                                                        &uidAddress,
                                                        0, NULL, &uidSize, &uid);
        if (uidStatus == noErr && uid) {
            OSStatus setStatus = AudioQueueSetProperty(queue,
                                                       kAudioQueueProperty_CurrentDevice,
                                                       &uid,
                                                       sizeof(CFStringRef));
            if (setStatus != noErr) {
                NSLog(@"[Koe] Failed to set input device (ID %u): %d — using system default",
                      (unsigned)self.pendingDeviceID, (int)setStatus);
            }
            CFRelease(uid);
        }
    }

    UInt32 bufferSize = kBufferFrames * sizeof(float);
    for (int i = 0; i < kNumBuffers; i++) {
        AudioQueueBufferRef audioBuffer = NULL;
        status = AudioQueueAllocateBuffer(queue, bufferSize, &audioBuffer);
        if (status != noErr) {
            NSLog(@"[Koe] Failed to allocate audio queue buffer %d: %d", i, (int)status);
            AudioQueueDispose(queue, true);
            return NO;
        }
        status = AudioQueueEnqueueBuffer(queue, audioBuffer, 0, NULL);
        if (status != noErr) {
            NSLog(@"[Koe] Failed to enqueue audio queue buffer %d: %d", i, (int)status);
            AudioQueueDispose(queue, true);
            return NO;
        }
    }

    self.audioQueue = queue;
    self.preparedDeviceID = self.pendingDeviceID;
    AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning,
                                  queueRunningChanged, (__bridge void *)self);
    NSLog(@"[Koe] Audio queue prepared in %.1fms (hardware inactive)",
          elapsedMillisecondsSince(prepareStartedAt));
    return YES;
}

- (BOOL)startPreparedQueue {
    if (self.isAudioQueueRunning) return YES;
    if (![self prepare]) return NO;

    uint64_t startCalledAt = mach_continuous_time();
    OSStatus status = AudioQueueStart(self.audioQueue, NULL);
    if (status != noErr) {
        NSLog(@"[Koe] Audio queue start failed: %d", (int)status);
        [self disposeQueue];
        return NO;
    }
    self.isAudioQueueRunning = YES;
    NSLog(@"[Koe] AudioQueueStart returned in %.1fms",
          elapsedMillisecondsSince(startCalledAt));
    return YES;
}

- (BOOL)beginPreCapture {
    @synchronized (self.accumBuffer) {
        self.isPreCapturing = YES;
        self.previousActivationStartedHostTime = self.activationStartedHostTime;
        self.previousActivationSequence = self.activationSequence;
        self.activationStartedHostTime = mach_continuous_time();
        self.activationSequence += 1;
        self.waitingForFirstCallback = YES;
        self.waitingForFirstFrame = YES;
        [self.preRollBuffer setLength:0];
        if (!self.isCapturing) {
            [self.accumBuffer setLength:0];
        }
    }

    NSLog(@"[Koe] Audio activation #%lu: trigger-down at 0.0ms",
          (unsigned long)self.activationSequence);

    if (![self startPreparedQueue]) {
        @synchronized (self.accumBuffer) {
            self.isPreCapturing = NO;
        }
        return NO;
    }

    NSLog(@"[Koe] Trigger-down pre-capture started");
    return YES;
}

- (void)cancelPreCapture {
    if (!self.isPreCapturing) return;
    if (self.isCapturing) {
        @synchronized (self.accumBuffer) {
            self.isPreCapturing = NO;
            [self.preRollBuffer setLength:0];
        }
        return;
    }
    NSLog(@"[Koe] Trigger gesture cancelled; stopping pre-capture");
    [self stopAndReprepare];
}

- (BOOL)startCaptureWithAudioCallback:(SPAudioFrameCallback)callback
                       includePreRoll:(BOOL)includePreRoll {
    if (!callback || (self.isCapturing && !self.isPreCapturing)) return NO;

    @synchronized (self.accumBuffer) {
        self.audioCallback = callback;
        self.isCapturing = YES;
        self.isPreCapturing = NO;
        [self.accumBuffer setLength:0];

        // Promote pre-roll while holding the same lock used by the queue
        // callback. This guarantees trigger-down audio is delivered before
        // any live frame produced after the session becomes armed.
        if (includePreRoll && self.preRollBuffer.length > 0) {
            NSLog(@"[Koe] Delivering %lu bytes of trigger-down pre-roll",
                  (unsigned long)self.preRollBuffer.length);
            uint64_t timestamp = mach_absolute_time();
            self.audioCallback(self.preRollBuffer.bytes,
                               (uint32_t)self.preRollBuffer.length,
                               timestamp);
        }
        [self.preRollBuffer setLength:0];
    }

    if (![self startPreparedQueue]) {
        @synchronized (self.accumBuffer) {
            self.audioCallback = nil;
            self.isCapturing = NO;
        }
        return NO;
    }

    NSLog(@"[Koe] Audio capture armed");
    return YES;
}

- (void)stopCapture {
    if (!self.isCapturing) return;

    @synchronized (self.accumBuffer) {
        self.isCapturing = NO;
        self.isPreCapturing = NO;
        if (self.accumBuffer.length > 0 && self.audioCallback) {
            NSLog(@"[Koe] Flushing remaining %lu bytes of audio",
                  (unsigned long)self.accumBuffer.length);
            uint64_t timestamp = mach_absolute_time();
            self.audioCallback(self.accumBuffer.bytes,
                               (uint32_t)self.accumBuffer.length,
                               timestamp);
        }
        self.audioCallback = nil;
        self.waitingForFirstCallback = NO;
        self.waitingForFirstFrame = NO;
        [self.accumBuffer setLength:0];
        [self.preRollBuffer setLength:0];
    }

    [self stopAndReprepare];
    NSLog(@"[Koe] Audio capture stopped");
}

- (void)stopAndReprepare {
    [self disposeQueue];
    [self prepare];
}

- (void)disposeQueue {
    @synchronized (self.accumBuffer) {
        self.isCapturing = NO;
        self.isPreCapturing = NO;
        self.isAudioQueueRunning = NO;
        self.audioCallback = nil;
        [self.accumBuffer setLength:0];
        [self.preRollBuffer setLength:0];
        self.preparedDeviceID = kAudioObjectUnknown;
        self.waitingForFirstCallback = NO;
        self.waitingForFirstFrame = NO;
    }

    if (self.audioQueue) {
        AudioQueueStop(self.audioQueue, true);
        AudioQueueDispose(self.audioQueue, true);
        self.audioQueue = NULL;
    }
}

- (void)shutdown {
    [self disposeQueue];
    NSLog(@"[Koe] Audio queue shut down");
}

- (void)logActivationMilestone:(NSString *)milestone {
    [self logActivationMilestone:milestone
          forActivationSequence:self.activationSequence];
}

- (void)logActivationMilestone:(NSString *)milestone
          forActivationSequence:(NSUInteger)activationSequence {
    if (milestone.length == 0 || activationSequence == 0) return;
    uint64_t startedAt = 0;
    if (activationSequence == self.activationSequence) {
        startedAt = self.activationStartedHostTime;
    } else if (activationSequence == self.previousActivationSequence) {
        startedAt = self.previousActivationStartedHostTime;
    }
    if (startedAt == 0) return;
    NSLog(@"[Koe] Audio activation #%lu: %@ at %.1fms",
          (unsigned long)activationSequence,
          milestone,
          elapsedMillisecondsSince(startedAt));
}

@end

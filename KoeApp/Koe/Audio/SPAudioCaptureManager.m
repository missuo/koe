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

// CoreAudio may synchronously wait on coreaudiod while devices or Bluetooth
// routes are being rebuilt. Keep those waits off the main thread and bound how
// long callers wait for the result. A timed-out operation retains exclusive
// ownership until its worker eventually returns, preventing overlapping retries.
static const NSTimeInterval kAudioLifecycleTimeoutSec = 3.0;

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

// All AudioQueue create/start/stop/dispose calls run on this serial queue.
// lifecycleOperationInFlight remains true after a timeout until the underlying
// CoreAudio call actually returns and late cleanup has completed.
@property (nonatomic) dispatch_queue_t lifecycleQueue;
@property (nonatomic, strong) NSObject *lifecycleLock;
@property (nonatomic, assign) NSUInteger lifecycleGeneration;
@property (nonatomic, assign) BOOL lifecycleOperationInFlight;

// Output muting during recording: silence other apps' playback so it neither
// distracts the speaker nor bleeds into the mic. Restored on stop/shutdown.
@property (nonatomic, assign) BOOL didMuteOutput;
@property (nonatomic, assign) AudioObjectID mutedOutputDevice;

// Output volume save/restore. When AirPods are used as the recording mic they
// switch A2DP→HFP, and macOS tracks media and call volume separately — so
// playback can come back at a different level once recording ends. Capture the
// pre-recording volume (while still A2DP) and re-assert it on stop. Guarded to a
// sane audible range so we never zero the user's playback.
@property (nonatomic, assign) BOOL didSaveVolume;
@property (nonatomic, assign) AudioObjectID savedVolumeDevice;
@property (nonatomic, assign) Float32 savedVolume;

- (BOOL)startPreparedQueue;
- (void)stopAndReprepare;
- (BOOL)disposeQueue;
- (BOOL)runLifecycleOperationNamed:(NSString *)name
                         operation:(BOOL (^)(void))operation
                        lateCleanup:(dispatch_block_t)lateCleanup;
- (void)muteSystemOutput;
- (void)restoreSystemOutput;
- (void)saveSystemOutputVolume;
- (void)restoreSystemOutputVolume;

@end

// ---------------------------------------------------------------------------
// System output muting — silence other playback while recording
// ---------------------------------------------------------------------------

static AudioObjectID koeDefaultOutputDevice(void) {
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL,
                                   &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static BOOL koeReadOutputVolume(AudioObjectID device, Float32 *outValue) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(device, &addr)) return NO;
    UInt32 size = sizeof(*outValue);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, outValue) != noErr) return NO;
    return size == sizeof(Float32); // reject a malformed HAL response
}

static BOOL koeWriteOutputVolume(AudioObjectID device, Float32 value) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    if (AudioObjectIsPropertySettable(device, &addr, &settable) != noErr || !settable) {
        return NO;
    }
    return AudioObjectSetPropertyData(device, &addr, 0, NULL, sizeof(value), &value) == noErr;
}

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
        _muteOutputEnabled = NO;
        _didMuteOutput = NO;
        _mutedOutputDevice = kAudioObjectUnknown;
        _didSaveVolume = NO;
        _savedVolumeDevice = kAudioObjectUnknown;
        _savedVolume = 0.0f;
        _lifecycleQueue = dispatch_queue_create("nz.owo.koe.audio-lifecycle",
                                                DISPATCH_QUEUE_SERIAL);
        _lifecycleLock = [[NSObject alloc] init];
    }
    return self;
}

- (BOOL)runLifecycleOperationNamed:(NSString *)name
                         operation:(BOOL (^)(void))operation
                        lateCleanup:(dispatch_block_t)lateCleanup {
    if (!operation) return NO;

    __block BOOL completed = NO;
    __block BOOL result = NO;
    NSUInteger generation = 0;

    @synchronized (self.lifecycleLock) {
        if (self.lifecycleOperationInFlight) {
            NSLog(@"[Koe] Audio %@ rejected: another lifecycle operation is still in flight",
                  name);
            return NO;
        }
        self.lifecycleOperationInFlight = YES;
        self.lifecycleGeneration += 1;
        generation = self.lifecycleGeneration;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(self.lifecycleQueue, ^{
        BOOL operationResult = operation();
        BOOL abandoned = NO;

        @synchronized (self.lifecycleLock) {
            abandoned = generation != self.lifecycleGeneration;
            if (!abandoned) {
                result = operationResult;
                completed = YES;
                self.lifecycleOperationInFlight = NO;
                // Signal while holding the handoff lock. If the deadline and
                // completion race, the waiter re-checks completed under this
                // same lock and accepts the completed result.
                dispatch_semaphore_signal(semaphore);
            }
        }

        if (abandoned) {
            if (lateCleanup) lateCleanup();
            @synchronized (self.lifecycleLock) {
                self.lifecycleOperationInFlight = NO;
            }
        }
    });

    long waitResult = dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kAudioLifecycleTimeoutSec * NSEC_PER_SEC)));

    @synchronized (self.lifecycleLock) {
        if (completed) return result;

        if (waitResult != 0 && generation == self.lifecycleGeneration) {
            // Invalidate publication by the worker. The in-flight flag stays
            // set until the worker returns and performs lateCleanup.
            self.lifecycleGeneration += 1;
        }
    }

    NSLog(@"[Koe] Audio %@ timed out after %.0fs; abandoning late result",
          name, kAudioLifecycleTimeoutSec);
    return NO;
}

- (void)setInputDeviceID:(AudioDeviceID)deviceID {
    if (self.pendingDeviceID == deviceID) return;
    self.pendingDeviceID = deviceID;
    BOOL shouldDispose = NO;
    @synchronized (self.lifecycleLock) {
        shouldDispose = self.audioQueue && !self.isAudioQueueRunning &&
                        self.preparedDeviceID != deviceID;
    }
    if (shouldDispose) {
        [self disposeQueue];
    }
}

- (BOOL)prepare {
    @synchronized (self.lifecycleLock) {
        if (self.audioQueue) return YES;
    }

    uint64_t prepareStartedAt = mach_continuous_time();
    AudioDeviceID pendingDeviceID = self.pendingDeviceID;
    __block AudioQueueRef preparedQueue = NULL;

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

    BOOL prepared = [self runLifecycleOperationNamed:@"queue preparation"
                                           operation:^BOOL{
        AudioQueueRef queue = NULL;
        OSStatus status = AudioQueueNewInput(&format, queueInputCallback,
                                             (__bridge void *)self,
                                             NULL, NULL, 0, &queue);
        if (status != noErr) {
            NSLog(@"[Koe] Failed to prepare audio queue: %d", (int)status);
            return NO;
        }
        preparedQueue = queue;

        if (pendingDeviceID != kAudioObjectUnknown) {
            AudioObjectPropertyAddress uidAddress = {
                kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            CFStringRef uid = NULL;
            UInt32 uidSize = sizeof(CFStringRef);
            OSStatus uidStatus = AudioObjectGetPropertyData(pendingDeviceID,
                                                            &uidAddress,
                                                            0, NULL,
                                                            &uidSize, &uid);
            if (uidStatus == noErr && uid) {
                OSStatus setStatus = AudioQueueSetProperty(
                    queue, kAudioQueueProperty_CurrentDevice,
                    &uid, sizeof(CFStringRef));
                if (setStatus != noErr) {
                    NSLog(@"[Koe] Failed to set input device (ID %u): %d — using system default",
                          (unsigned)pendingDeviceID, (int)setStatus);
                }
                CFRelease(uid);
            }
        }

        UInt32 bufferSize = kBufferFrames * sizeof(float);
        for (int i = 0; i < kNumBuffers; i++) {
            AudioQueueBufferRef audioBuffer = NULL;
            status = AudioQueueAllocateBuffer(queue, bufferSize, &audioBuffer);
            if (status != noErr) {
                NSLog(@"[Koe] Failed to allocate audio queue buffer %d: %d",
                      i, (int)status);
                AudioQueueDispose(queue, true);
                preparedQueue = NULL;
                return NO;
            }
            status = AudioQueueEnqueueBuffer(queue, audioBuffer, 0, NULL);
            if (status != noErr) {
                NSLog(@"[Koe] Failed to enqueue audio queue buffer %d: %d",
                      i, (int)status);
                AudioQueueDispose(queue, true);
                preparedQueue = NULL;
                return NO;
            }
        }

        AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning,
                                      queueRunningChanged,
                                      (__bridge void *)self);
        return YES;
    } lateCleanup:^{
        if (preparedQueue) {
            AudioQueueDispose(preparedQueue, true);
            preparedQueue = NULL;
        }
    }];

    if (!prepared || !preparedQueue) return NO;

    @synchronized (self.lifecycleLock) {
        self.audioQueue = preparedQueue;
        self.preparedDeviceID = pendingDeviceID;
    }
    NSLog(@"[Koe] Audio queue prepared in %.1fms (hardware inactive)",
          elapsedMillisecondsSince(prepareStartedAt));
    return YES;
}

- (BOOL)startPreparedQueue {
    if (self.isAudioQueueRunning) return YES;
    if (![self prepare]) return NO;

    AudioQueueRef queue = NULL;
    @synchronized (self.lifecycleLock) {
        queue = self.audioQueue;
    }
    if (!queue) return NO;

    uint64_t startCalledAt = mach_continuous_time();
    __block OSStatus status = noErr;
    BOOL started = [self runLifecycleOperationNamed:@"queue start"
                                          operation:^BOOL{
        status = AudioQueueStart(queue, NULL);
        return status == noErr;
    } lateCleanup:^{
        // The caller has already abandoned this generation. A queue that
        // starts after the timeout must never remain active or publish audio.
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
        @synchronized (self.lifecycleLock) {
            if (self.audioQueue == queue) {
                self.audioQueue = NULL;
                self.preparedDeviceID = kAudioObjectUnknown;
            }
        }
        self.isAudioQueueRunning = NO;
    }];
    if (!started) {
        if (status != noErr) {
            NSLog(@"[Koe] Audio queue start failed: %d", (int)status);
        }
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

    // Capture the output volume now, while the device is still A2DP — starting
    // the queue below switches AirPods to HFP and can leave a different level
    // behind. Only the first activation in a session needs this.
    if (!self.isAudioQueueRunning) {
        [self saveSystemOutputVolume];
    }

    if (![self startPreparedQueue]) {
        @synchronized (self.accumBuffer) {
            self.isPreCapturing = NO;
        }
        [self restoreSystemOutputVolume];
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
    [self restoreSystemOutputVolume];
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

    if (self.muteOutputEnabled) {
        [self muteSystemOutput];
    }

    NSLog(@"[Koe] Audio capture armed");
    return YES;
}

- (void)stopCapture {
    if (!self.isCapturing) {
        // Still restore in case mute was left on after a partial failure.
        [self restoreSystemOutput];
        if (self.isPreCapturing || self.isAudioQueueRunning) {
            [self stopAndReprepare];
        }
        [self restoreSystemOutputVolume];
        return;
    }

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

    [self restoreSystemOutput];
    [self stopAndReprepare];
    // Re-assert the saved A2DP volume only after the input queue has stopped;
    // restoring it while AirPods are still in HFP would update call volume.
    [self restoreSystemOutputVolume];
    NSLog(@"[Koe] Audio capture stopped");
}

- (void)stopAndReprepare {
    if ([self disposeQueue]) {
        [self prepare];
    }
}

- (BOOL)disposeQueue {
    @synchronized (self.accumBuffer) {
        self.isCapturing = NO;
        self.isPreCapturing = NO;
        self.isAudioQueueRunning = NO;
        self.audioCallback = nil;
        [self.accumBuffer setLength:0];
        [self.preRollBuffer setLength:0];
        self.waitingForFirstCallback = NO;
        self.waitingForFirstFrame = NO;
    }

    AudioQueueRef queue = NULL;
    @synchronized (self.lifecycleLock) {
        queue = self.audioQueue;
        self.audioQueue = NULL;
        self.preparedDeviceID = kAudioObjectUnknown;
    }

    if (!queue) return YES;

    return [self runLifecycleOperationNamed:@"queue teardown"
                                  operation:^BOOL{
        OSStatus stopStatus = AudioQueueStop(queue, true);
        OSStatus disposeStatus = AudioQueueDispose(queue, true);
        if (stopStatus != noErr || disposeStatus != noErr) {
            NSLog(@"[Koe] Audio queue teardown errors: stop=%d dispose=%d",
                  (int)stopStatus, (int)disposeStatus);
        }
        return stopStatus == noErr && disposeStatus == noErr;
    } lateCleanup:nil];
}

- (void)shutdown {
    [self restoreSystemOutput];
    [self disposeQueue];
    [self restoreSystemOutputVolume];
    NSLog(@"[Koe] Audio queue shut down");
}

- (void)restoreMutedSystemOutputIfNeeded {
    [self restoreSystemOutput];
}

#pragma mark - System Output Muting

// Mute the current default output device so other apps' audio is silenced for
// the duration of the recording. The device we mute is remembered so we restore
// exactly that one even if the default route changes mid-session. If the device
// was already muted by the user, we leave it untouched and skip the restore.
- (void)muteSystemOutput {
    self.didMuteOutput = NO;
    self.mutedOutputDevice = kAudioObjectUnknown;

    AudioObjectID device = koeDefaultOutputDevice();
    if (device == kAudioObjectUnknown) return;

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(device, &addr)) {
        NSLog(@"[Koe] Default output device has no master mute; skipping output mute");
        return;
    }

    UInt32 muted = 0;
    UInt32 size = sizeof(muted);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &muted) != noErr) return;
    if (muted) return; // already muted by the user — don't touch, don't restore

    UInt32 on = 1;
    if (AudioObjectSetPropertyData(device, &addr, 0, NULL, sizeof(on), &on) == noErr) {
        self.mutedOutputDevice = device;
        self.didMuteOutput = YES;
        NSLog(@"[Koe] Muted system output during recording (device %u)", (unsigned)device);
    }
}

- (void)restoreSystemOutput {
    if (!self.didMuteOutput) return;
    self.didMuteOutput = NO;

    AudioObjectID device = self.mutedOutputDevice;
    self.mutedOutputDevice = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown) return;

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 off = 0;
    if (AudioObjectSetPropertyData(device, &addr, 0, NULL, sizeof(off), &off) == noErr) {
        NSLog(@"[Koe] Restored system output after recording");
    }
}

// Remember the current output volume before the mic opens (and the AirPods
// A2DP→HFP switch perturbs it). Only an audible level is remembered: a device
// at/near zero is left alone so we never write a value that would silence
// playback when restored.
- (void)saveSystemOutputVolume {
    self.didSaveVolume = NO;
    self.savedVolumeDevice = kAudioObjectUnknown;

    AudioObjectID device = koeDefaultOutputDevice();
    if (device == kAudioObjectUnknown) return;

    Float32 volume = 0.0f;
    if (!koeReadOutputVolume(device, &volume)) return;
    if (volume < 0.05f || volume > 1.0f) return; // out of audible range — don't touch

    self.savedVolumeDevice = device;
    self.savedVolume = volume;
    self.didSaveVolume = YES;
}

- (void)restoreSystemOutputVolume {
    if (!self.didSaveVolume) return;
    self.didSaveVolume = NO;

    AudioObjectID device = self.savedVolumeDevice;
    self.savedVolumeDevice = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown) return;

    // The output route can change mid-recording (AirPods disconnect, manual
    // switch) and CoreAudio reuses device IDs — so only re-assert the level if
    // the saved device is still the default output. Writing our remembered level
    // to a device that ID now points at could blast its volume.
    if (koeDefaultOutputDevice() != device) return;

    if (koeWriteOutputVolume(device, self.savedVolume)) {
        NSLog(@"[Koe] Restored output volume %.2f after recording", self.savedVolume);
    }
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

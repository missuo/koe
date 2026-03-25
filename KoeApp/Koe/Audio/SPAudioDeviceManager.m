#import "SPAudioDeviceManager.h"
#import <CoreAudio/CoreAudio.h>

static NSString *const kSelectedDeviceUIDKey = @"SPSelectedAudioDeviceUID";
static NSString *const kSelectedDeviceNameKey = @"SPSelectedAudioDeviceName";

#pragma mark - SPAudioInputDevice

@implementation SPAudioInputDevice

- (instancetype)initWithUID:(NSString *)uid name:(NSString *)name deviceID:(AudioDeviceID)deviceID {
    self = [super init];
    if (self) {
        _uid = [uid copy];
        _name = [name copy];
        _deviceID = deviceID;
    }
    return self;
}

@end

#pragma mark - SPAudioDeviceManager

@interface SPAudioDeviceManager ()
- (void)handleDeviceListChanged;
@end

static OSStatus deviceListChangedCallback(AudioObjectID inObjectID,
                                           UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress inAddresses[],
                                           void *inClientData) {
    SPAudioDeviceManager *manager = (__bridge SPAudioDeviceManager *)inClientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [manager handleDeviceListChanged];
    });
    return noErr;
}

@implementation SPAudioDeviceManager

- (NSArray<SPAudioInputDevice *> *)availableInputDevices {
    // Get all audio devices
    AudioObjectPropertyAddress devicesAddress = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &dataSize);
    if (status != noErr || dataSize == 0) {
        NSLog(@"[Koe] Failed to get audio device list size: %d", (int)status);
        return @[];
    }

    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(dataSize);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &dataSize, deviceIDs);
    if (status != noErr) {
        NSLog(@"[Koe] Failed to get audio device list: %d", (int)status);
        free(deviceIDs);
        return @[];
    }

    NSMutableArray<SPAudioInputDevice *> *inputDevices = [NSMutableArray array];

    for (UInt32 i = 0; i < deviceCount; i++) {
        AudioDeviceID deviceID = deviceIDs[i];

        // Skip aggregate devices (internal system devices, e.g. CADefaultDeviceAggregate).
        // NOTE: This also filters out user-created aggregate devices from Audio MIDI Setup.
        // This is a deliberate trade-off to keep the list clean for the common case.
        // If user-created aggregates need to be supported in the future, switch to a
        // name-based blocklist (e.g. skip only devices whose name starts with "CADefault").
        AudioObjectPropertyAddress transportAddress = {
            .mSelector = kAudioDevicePropertyTransportType,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };

        UInt32 transportType = 0;
        UInt32 transportSize = sizeof(UInt32);
        status = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, NULL, &transportSize, &transportType);
        if (status == noErr && transportType == kAudioDeviceTransportTypeAggregate) continue;

        // Check if this device has input channels
        AudioObjectPropertyAddress streamConfigAddress = {
            .mSelector = kAudioDevicePropertyStreamConfiguration,
            .mScope = kAudioObjectPropertyScopeInput,
            .mElement = kAudioObjectPropertyElementMain
        };

        UInt32 configSize = 0;
        status = AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddress, 0, NULL, &configSize);
        if (status != noErr || configSize == 0) continue;

        AudioBufferList *bufferList = (AudioBufferList *)malloc(configSize);
        status = AudioObjectGetPropertyData(deviceID, &streamConfigAddress, 0, NULL, &configSize, bufferList);
        if (status != noErr) {
            free(bufferList);
            continue;
        }

        // Count input channels
        UInt32 inputChannels = 0;
        for (UInt32 j = 0; j < bufferList->mNumberBuffers; j++) {
            inputChannels += bufferList->mBuffers[j].mNumberChannels;
        }
        free(bufferList);

        if (inputChannels == 0) continue;

        // Get device UID
        AudioObjectPropertyAddress uidAddress = {
            .mSelector = kAudioDevicePropertyDeviceUID,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };

        CFStringRef deviceUID = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, NULL, &uidSize, &deviceUID);
        if (status != noErr || !deviceUID) continue;

        // Get device name
        AudioObjectPropertyAddress nameAddress = {
            .mSelector = kAudioObjectPropertyName,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };

        CFStringRef deviceName = NULL;
        UInt32 nameSize = sizeof(CFStringRef);
        status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &nameSize, &deviceName);
        if (status != noErr || !deviceName) {
            CFRelease(deviceUID);
            continue;
        }

        SPAudioInputDevice *device = [[SPAudioInputDevice alloc] initWithUID:(__bridge NSString *)deviceUID
                                                                        name:(__bridge NSString *)deviceName
                                                                    deviceID:deviceID];
        [inputDevices addObject:device];

        CFRelease(deviceUID);
        CFRelease(deviceName);
    }

    free(deviceIDs);

    // Sort by name
    [inputDevices sortUsingComparator:^NSComparisonResult(SPAudioInputDevice *a, SPAudioInputDevice *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    return [inputDevices copy];
}

- (NSString *)selectedDeviceUID {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedDeviceUIDKey];
}

- (void)setSelectedDeviceUID:(NSString *)selectedDeviceUID {
    if (selectedDeviceUID) {
        [[NSUserDefaults standardUserDefaults] setObject:selectedDeviceUID forKey:kSelectedDeviceUIDKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedDeviceUIDKey];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedDeviceNameKey];
    }
}

- (NSString *)selectedDeviceName {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedDeviceNameKey];
}

- (void)selectDevice:(NSString *)uid name:(NSString *)name {
    if (uid) {
        [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kSelectedDeviceUIDKey];
        if (name) {
            [[NSUserDefaults standardUserDefaults] setObject:name forKey:kSelectedDeviceNameKey];
        }
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedDeviceUIDKey];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedDeviceNameKey];
    }
}

- (AudioDeviceID)resolvedDeviceID {
    NSString *selectedUID = self.selectedDeviceUID;

    if (selectedUID) {
        // Try to find the selected device
        NSArray<SPAudioInputDevice *> *devices = [self availableInputDevices];
        for (SPAudioInputDevice *device in devices) {
            if ([device.uid isEqualToString:selectedUID]) {
                return device.deviceID;
            }
        }
        NSLog(@"[Koe] Selected audio device %@ not found, falling back to system default", selectedUID);
    }

    // Return kAudioObjectUnknown so SPAudioCaptureManager lets AVAudioEngine
    // use its own default device handling instead of explicitly setting one.
    return kAudioObjectUnknown;
}

- (BOOL)isSelectedDeviceAvailable {
    NSString *uid = self.selectedDeviceUID;
    if (!uid) return YES; // System default is always available
    for (SPAudioInputDevice *device in [self availableInputDevices]) {
        if ([device.uid isEqualToString:uid]) return YES;
    }
    return NO;
}

- (void)startListening {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &address,
                                                      deviceListChangedCallback,
                                                      (__bridge void *)self);
    if (status != noErr) {
        NSLog(@"[Koe] Failed to register audio device change listener: %d", (int)status);
    } else {
        NSLog(@"[Koe] Audio device change listener registered");
    }
}

- (void)stopListening {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &address,
                                       deviceListChangedCallback,
                                       (__bridge void *)self);
}

- (void)handleDeviceListChanged {
    NSLog(@"[Koe] Audio device list changed");
    if ([self.delegate respondsToSelector:@selector(audioDeviceManagerDeviceListDidChange)]) {
        [self.delegate audioDeviceManagerDeviceListDidChange];
    }
}

@end

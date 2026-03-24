#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a single audio input device.
@interface SPAudioInputDevice : NSObject

@property (nonatomic, copy, readonly) NSString *uid;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, assign, readonly) AudioDeviceID deviceID;

- (instancetype)initWithUID:(NSString *)uid name:(NSString *)name deviceID:(AudioDeviceID)deviceID;

@end

/// Manages audio input device enumeration, selection, and persistence.
@interface SPAudioDeviceManager : NSObject

/// Returns all available audio input devices, ordered by name.
- (NSArray<SPAudioInputDevice *> *)availableInputDevices;

/// The currently selected device UID, or nil for system default.
@property (nonatomic, copy, nullable) NSString *selectedDeviceUID;

/// The display name of the currently selected device, or nil.
/// Persisted alongside the UID so the name can be shown even when the device is disconnected.
@property (nonatomic, readonly, nullable) NSString *selectedDeviceName;

/// Sets the selected device UID and name together. Pass nil for both to revert to system default.
- (void)selectDevice:(nullable NSString *)uid name:(nullable NSString *)name;

/// Resolves the selected UID to an AudioDeviceID.
/// Returns the system default input device if the stored UID is nil or no longer available.
- (AudioDeviceID)resolvedDeviceID;

@end

NS_ASSUME_NONNULL_END

#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <string>
#include <vector>

struct AudioInputDevice {
    std::wstring id;    // MMDevice endpoint ID
    std::wstring name;  // Friendly display name
};

class AudioDeviceManager {
public:
    // Enumerate all active capture endpoints, sorted by name
    std::vector<AudioInputDevice> availableInputDevices();

    // Get/set selected device endpoint ID (empty = system default)
    std::wstring selectedDeviceId();
    void setSelectedDeviceId(const wchar_t* id);

    // Returns selected ID if device still available, else empty (system default)
    std::wstring resolvedDeviceId();
};

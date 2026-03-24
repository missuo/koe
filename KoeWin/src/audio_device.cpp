#include "audio_device.h"
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <algorithm>
#include <cstdio>

static const wchar_t* kRegKeyPath = L"SOFTWARE\\Koe";
static const wchar_t* kRegValueName = L"SelectedAudioDeviceId";

std::vector<AudioInputDevice> AudioDeviceManager::availableInputDevices() {
    std::vector<AudioInputDevice> devices;

    IMMDeviceEnumerator* enumerator = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                   __uuidof(IMMDeviceEnumerator),
                                   reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) return devices;

    IMMDeviceCollection* collection = nullptr;
    hr = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(hr)) {
        enumerator->Release();
        return devices;
    }

    UINT count = 0;
    collection->GetCount(&count);

    for (UINT i = 0; i < count; i++) {
        IMMDevice* device = nullptr;
        if (FAILED(collection->Item(i, &device))) continue;

        // Get endpoint ID
        LPWSTR deviceId = nullptr;
        if (FAILED(device->GetId(&deviceId))) {
            device->Release();
            continue;
        }

        // Get friendly name
        IPropertyStore* props = nullptr;
        std::wstring friendlyName;
        if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
            PROPVARIANT varName;
            PropVariantInit(&varName);
            if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &varName))) {
                if (varName.vt == VT_LPWSTR && varName.pwszVal) {
                    friendlyName = varName.pwszVal;
                }
            }
            PropVariantClear(&varName);
            props->Release();
        }

        if (!friendlyName.empty()) {
            devices.push_back({ deviceId, friendlyName });
        }

        CoTaskMemFree(deviceId);
        device->Release();
    }

    collection->Release();
    enumerator->Release();

    // Sort by name
    std::sort(devices.begin(), devices.end(),
              [](const AudioInputDevice& a, const AudioInputDevice& b) {
                  return _wcsicmp(a.name.c_str(), b.name.c_str()) < 0;
              });

    return devices;
}

std::wstring AudioDeviceManager::selectedDeviceId() {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKeyPath, 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
        return L"";
    }

    wchar_t buf[512] = {};
    DWORD size = sizeof(buf);
    DWORD type = 0;
    LSTATUS status = RegQueryValueExW(hKey, kRegValueName, nullptr, &type,
                                       reinterpret_cast<LPBYTE>(buf), &size);
    RegCloseKey(hKey);

    if (status == ERROR_SUCCESS && type == REG_SZ) {
        return buf;
    }
    return L"";
}

void AudioDeviceManager::setSelectedDeviceId(const wchar_t* id) {
    HKEY hKey;
    if (id && wcslen(id) > 0) {
        if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKeyPath, 0, nullptr,
                            0, KEY_SET_VALUE, nullptr, &hKey, nullptr) == ERROR_SUCCESS) {
            RegSetValueExW(hKey, kRegValueName, 0, REG_SZ,
                           reinterpret_cast<const BYTE*>(id),
                           static_cast<DWORD>((wcslen(id) + 1) * sizeof(wchar_t)));
            RegCloseKey(hKey);
        }
    } else {
        // Delete = revert to system default
        if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKeyPath, 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
            RegDeleteValueW(hKey, kRegValueName);
            RegCloseKey(hKey);
        }
    }
}

std::wstring AudioDeviceManager::resolvedDeviceId() {
    std::wstring saved = selectedDeviceId();
    if (saved.empty()) return L"";

    // Check if saved device still exists
    auto devices = availableInputDevices();
    for (const auto& dev : devices) {
        if (dev.id == saved) return saved;
    }

    OutputDebugStringA("[Koe] Saved audio device not found, falling back to system default\n");
    return L"";
}

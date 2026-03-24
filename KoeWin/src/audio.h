#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <functional>

using AudioFrameCallback = std::function<void(const uint8_t* buffer, uint32_t length, uint64_t timestamp)>;

class AudioCapture {
public:
    AudioCapture();
    ~AudioCapture();

    void start(AudioFrameCallback callback);
    void stop();
    bool isCapturing() const { return m_capturing; }

private:
    static DWORD WINAPI captureThread(LPVOID param);
    void captureLoop();

    AudioFrameCallback m_callback;
    HANDLE m_thread = nullptr;
    HANDLE m_stopEvent = nullptr;
    bool m_capturing = false;
};

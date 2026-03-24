#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>

// Custom message IDs for Rust callback dispatch (main.cpp WndProc handles these)
#define WM_RUST_SESSION_READY   (WM_APP + 1)
#define WM_RUST_SESSION_ERROR   (WM_APP + 2)
#define WM_RUST_SESSION_WARNING (WM_APP + 3)
#define WM_RUST_FINAL_TEXT      (WM_APP + 4)
#define WM_RUST_LOG_EVENT       (WM_APP + 5)
#define WM_RUST_STATE_CHANGED   (WM_APP + 6)

class RustBridge {
public:
    explicit RustBridge(HWND messageWindow);

    void initialize();
    void destroy();
    void beginSession(int mode);  // 0=Hold, 1=Toggle
    void pushAudio(const uint8_t* frame, uint32_t len, uint64_t timestamp);
    void endSession();
    void reloadConfig();

private:
    HWND m_hwnd;
};

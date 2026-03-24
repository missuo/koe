#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>

// Hotkey detection delegate
class HotkeyDelegate {
public:
    virtual ~HotkeyDelegate() = default;
    virtual void hotkeyDidDetectHoldStart() = 0;
    virtual void hotkeyDidDetectHoldEnd() = 0;
    virtual void hotkeyDidDetectTapStart() = 0;
    virtual void hotkeyDidDetectTapEnd() = 0;
};

// Custom messages for keyboard hook -> main thread
#define WM_HOTKEY_KEYDOWN   (WM_APP + 10)
#define WM_HOTKEY_KEYUP     (WM_APP + 11)

class HotkeyMonitor {
public:
    HotkeyMonitor(HWND messageWindow, HotkeyDelegate* delegate);
    ~HotkeyMonitor();

    void start();
    void stop();

    uint16_t targetKeyCode = 0xA3;  // VK_RCONTROL default
    double holdThresholdMs = 180.0;
    bool suspended = false;
    bool consumeKey = true;  // Swallow target key events when active

    // Called from WndProc on main thread
    void handleKeyDown();
    void handleKeyUp();

private:
    void handleHoldTimer();

    HWND m_hwnd;
    HotkeyDelegate* m_delegate;
    HHOOK m_hook = nullptr;
    UINT_PTR m_holdTimerId = 0;

    enum State {
        Idle,
        Pending,         // Key pressed, waiting to determine tap vs hold
        RecordingHold,   // Confirmed hold
        RecordingToggle, // Confirmed tap, free-hands recording
        ConsumeKeyUp,    // Waiting to consume keyUp after toggle-stop
    };
    State m_state = Idle;
    bool m_keyDown = false;

    static LRESULT CALLBACK keyboardProc(int nCode, WPARAM wParam, LPARAM lParam);
    static void CALLBACK holdTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD time);
};

// Global instance pointer (needed for static hook callback)
extern HotkeyMonitor* g_hotkeyMonitor;

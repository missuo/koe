#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "hotkey.h"
#include "tray.h"

class RustBridge;
class AudioCapture;
class ClipboardManager;
class PasteManager;
class CuePlayer;
class OverlayPanel;
class HistoryManager;

// Timer IDs
#define TIMER_CLIPBOARD_RESTORE 2001
#define TIMER_PASTE_DELAY       2002
#define TIMER_POST_PASTE        2003
#define TIMER_TRAILING_AUDIO    2004
#define TIMER_ERROR_RESET       2005
#define TIMER_CONFIG_WATCH      2006

class App : public HotkeyDelegate, public TrayDelegate {
public:
    explicit App(HWND messageWindow, HINSTANCE hInstance);
    ~App();

    void initialize();
    void shutdown();

    // Rust callback handlers (called on main thread via WndProc)
    void onSessionReady();
    void onSessionError(const wchar_t* message);
    void onSessionWarning(const wchar_t* message);
    void onFinalTextReady(const wchar_t* text);
    void onLogEvent(int level, const char* message);
    void onStateChanged(const char* state);

    // Timer handler (called from WndProc)
    void onTimer(UINT_PTR timerId);

    // Hotkey message handlers (called from WndProc)
    void onHotkeyKeyDown();
    void onHotkeyKeyUp();

    // Tray message handler (called from WndProc)
    void onTrayMessage(WPARAM wParam, LPARAM lParam);

    // HotkeyDelegate
    void hotkeyDidDetectHoldStart() override;
    void hotkeyDidDetectHoldEnd() override;
    void hotkeyDidDetectTapStart() override;
    void hotkeyDidDetectTapEnd() override;

    // TrayDelegate
    void trayMenuDidOpen() override;
    void trayMenuDidClose() override;
    void trayDidSelectQuit() override;

private:
    void beginRecording(int mode);
    void endRecording();
    void checkConfigFileChanged();

    HWND m_hwnd;
    HINSTANCE m_hInstance;
    RustBridge* m_bridge = nullptr;
    AudioCapture* m_audio = nullptr;
    ClipboardManager* m_clipboard = nullptr;
    PasteManager* m_paste = nullptr;
    CuePlayer* m_cue = nullptr;
    HotkeyMonitor* m_hotkey = nullptr;
    TrayManager* m_tray = nullptr;
    OverlayPanel* m_overlay = nullptr;
    HistoryManager* m_history = nullptr;

    LARGE_INTEGER m_recordingStartTime = {};
    LARGE_INTEGER m_perfFreq = {};
    FILETIME m_lastConfigModTime = {};
};

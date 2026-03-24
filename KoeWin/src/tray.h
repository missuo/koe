#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <cstdint>

#define WM_TRAY_ICON    (WM_APP + 20)
#define TIMER_TRAY_ANIM 3001

// Forward declarations
struct HistoryStats;
class AudioDeviceManager;

class TrayDelegate {
public:
    virtual ~TrayDelegate() = default;
    virtual void trayMenuDidOpen() = 0;
    virtual void trayMenuDidClose() = 0;
    virtual void trayDidSelectQuit() = 0;
    virtual void trayDidSelectAudioDevice(const wchar_t* id) = 0;
};

class TrayManager {
public:
    TrayManager(HWND messageWindow, TrayDelegate* delegate, AudioDeviceManager* audioDeviceManager);
    ~TrayManager();

    void create();
    void destroy();
    void updateState(const char* state);
    void onTrayMessage(WPARAM wParam, LPARAM lParam);
    void onAnimationTimer();

    // Set stats to show in menu (called before menu opens)
    void setStats(int64_t sessionCount, int64_t totalDurationMs,
                  int64_t totalCharCount, int64_t totalWordCount);

private:
    void showContextMenu();
    void applyIcon();

    // Icon drawing
    HICON drawIdleIcon();
    HICON drawRecordingIcon(int frame);
    HICON drawProcessingIcon(int frame);
    HICON drawSuccessIcon();
    HICON drawErrorIcon();

    bool isDarkTaskbar();
    int getIconSize();

    HWND m_hwnd;
    TrayDelegate* m_delegate;
    AudioDeviceManager* m_audioDeviceManager;
    NOTIFYICONDATAW m_nid = {};
    bool m_created = false;

    const char* m_currentState = "idle";
    int m_animFrame = 0;
    HICON m_currentIcon = nullptr;

    // Stats for context menu
    int64_t m_sessionCount = 0;
    int64_t m_totalDurationMs = 0;
    int64_t m_totalCharCount = 0;
    int64_t m_totalWordCount = 0;
};

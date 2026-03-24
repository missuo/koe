#include "tray.h"
#include "audio_device.h"
#include <objidl.h>
#include <gdiplus.h>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#pragma comment(lib, "gdiplus.lib")

using namespace Gdiplus;

static ULONG_PTR g_gdiplusToken = 0;

// Menu item IDs
enum {
    IDM_STATUS = 1000,
    IDM_STATS_COUNT,
    IDM_STATS_TIME,
    IDM_STATS_SPEED,
    IDM_OPEN_CONFIG,
    IDM_LAUNCH_AT_LOGIN,
    IDM_QUIT,
    IDM_MIC_DEFAULT = 1100,
    IDM_MIC_DEVICE  = 1200,  // 1200 + index for each device
};

TrayManager::TrayManager(HWND messageWindow, TrayDelegate* delegate, AudioDeviceManager* audioDeviceManager)
    : m_hwnd(messageWindow), m_delegate(delegate), m_audioDeviceManager(audioDeviceManager) {}

TrayManager::~TrayManager() {
    destroy();
}

void TrayManager::create() {
    // Initialize GDI+
    if (g_gdiplusToken == 0) {
        GdiplusStartupInput input;
        GdiplusStartup(&g_gdiplusToken, &input, nullptr);
    }

    // Create tray icon
    m_nid = {};
    m_nid.cbSize = sizeof(m_nid);
    m_nid.hWnd = m_hwnd;
    m_nid.uID = 1;
    m_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    m_nid.uCallbackMessage = WM_TRAY_ICON;
    wcscpy_s(m_nid.szTip, L"Koe — Voice Input");
    m_nid.hIcon = drawIdleIcon();
    m_currentIcon = m_nid.hIcon;

    Shell_NotifyIconW(NIM_ADD, &m_nid);
    m_created = true;
}

void TrayManager::destroy() {
    if (m_created) {
        Shell_NotifyIconW(NIM_DELETE, &m_nid);
        m_created = false;
    }
    if (m_currentIcon) {
        DestroyIcon(m_currentIcon);
        m_currentIcon = nullptr;
    }
}

void TrayManager::updateState(const char* state) {
    m_currentState = state;
    m_animFrame = 0;

    // Stop any running animation timer
    KillTimer(m_hwnd, TIMER_TRAY_ANIM);

    // Determine if we need animation
    bool needsAnim = false;
    if (strncmp(state, "recording", 9) == 0) {
        needsAnim = true;
        SetTimer(m_hwnd, TIMER_TRAY_ANIM, 150, nullptr);  // 150ms for recording
    } else if (strcmp(state, "connecting_asr") == 0 ||
               strcmp(state, "finalizing_asr") == 0 ||
               strcmp(state, "correcting") == 0) {
        needsAnim = true;
        SetTimer(m_hwnd, TIMER_TRAY_ANIM, 200, nullptr);  // 200ms for processing
    }

    applyIcon();
}

void TrayManager::onAnimationTimer() {
    m_animFrame++;
    applyIcon();
}

void TrayManager::applyIcon() {
    HICON newIcon = nullptr;

    if (strcmp(m_currentState, "idle") == 0 || strcmp(m_currentState, "completed") == 0) {
        newIcon = drawIdleIcon();
    } else if (strncmp(m_currentState, "recording", 9) == 0) {
        newIcon = drawRecordingIcon(m_animFrame);
    } else if (strncmp(m_currentState, "preparing_paste", 15) == 0 ||
               strcmp(m_currentState, "pasting") == 0) {
        newIcon = drawSuccessIcon();
    } else if (strcmp(m_currentState, "error") == 0 || strcmp(m_currentState, "failed") == 0) {
        newIcon = drawErrorIcon();
    } else {
        newIcon = drawProcessingIcon(m_animFrame);
    }

    if (newIcon) {
        if (m_currentIcon) DestroyIcon(m_currentIcon);
        m_currentIcon = newIcon;
        m_nid.hIcon = newIcon;
        m_nid.uFlags = NIF_ICON;
        Shell_NotifyIconW(NIM_MODIFY, &m_nid);
    }
}

void TrayManager::onTrayMessage(WPARAM wParam, LPARAM lParam) {
    UINT msg = LOWORD(lParam);
    if (msg == WM_RBUTTONUP || msg == WM_CONTEXTMENU) {
        showContextMenu();
    }
}

void TrayManager::showContextMenu() {
    if (m_delegate) m_delegate->trayMenuDidOpen();

    HMENU menu = CreatePopupMenu();

    // Status
    const char* statusText = "Ready";
    if (strncmp(m_currentState, "recording", 9) == 0) statusText = "Listening...";
    else if (strcmp(m_currentState, "connecting_asr") == 0) statusText = "Connecting...";
    else if (strcmp(m_currentState, "finalizing_asr") == 0) statusText = "Recognizing...";
    else if (strcmp(m_currentState, "correcting") == 0) statusText = "Thinking...";
    else if (strcmp(m_currentState, "pasting") == 0) statusText = "Pasting...";
    else if (strcmp(m_currentState, "error") == 0) statusText = "Error";

    wchar_t wStatus[64];
    MultiByteToWideChar(CP_UTF8, 0, statusText, -1, wStatus, 64);
    AppendMenuW(menu, MF_STRING | MF_DISABLED, IDM_STATUS, wStatus);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    // Statistics
    wchar_t buf[256];
    if (m_totalCharCount > 0 || m_totalWordCount > 0) {
        if (m_totalCharCount > m_totalWordCount) {
            swprintf_s(buf, L"Total: %lld chars", m_totalCharCount);
        } else {
            swprintf_s(buf, L"Total: %lld words", m_totalWordCount);
        }
    } else {
        wcscpy_s(buf, L"Total: No data yet");
    }
    AppendMenuW(menu, MF_STRING | MF_DISABLED, IDM_STATS_COUNT, buf);

    if (m_sessionCount > 0) {
        int64_t totalSec = m_totalDurationMs / 1000;
        swprintf_s(buf, L"Time: %lld min %lld sec | %lld sessions",
                   totalSec / 60, totalSec % 60, m_sessionCount);
    } else {
        wcscpy_s(buf, L"Time: --");
    }
    AppendMenuW(menu, MF_STRING | MF_DISABLED, IDM_STATS_TIME, buf);

    if (m_totalDurationMs > 0 && (m_totalCharCount + m_totalWordCount) > 0) {
        double minutes = static_cast<double>(m_totalDurationMs) / 60000.0;
        if (m_totalCharCount > m_totalWordCount) {
            swprintf_s(buf, L"Speed: %.0f chars/min", m_totalCharCount / minutes);
        } else {
            swprintf_s(buf, L"Speed: %.0f words/min", m_totalWordCount / minutes);
        }
    } else {
        wcscpy_s(buf, L"Speed: --");
    }
    AppendMenuW(menu, MF_STRING | MF_DISABLED, IDM_STATS_SPEED, buf);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    // Microphone submenu
    std::vector<AudioInputDevice> micDevices;
    std::wstring selectedMicId;
    HMENU micMenu = CreatePopupMenu();
    if (m_audioDeviceManager) {
        micDevices = m_audioDeviceManager->availableInputDevices();
        selectedMicId = m_audioDeviceManager->selectedDeviceId();
    }

    // "System Default" always first
    AppendMenuW(micMenu, MF_STRING | (selectedMicId.empty() ? MF_CHECKED : 0),
                IDM_MIC_DEFAULT, L"System Default");

    if (!micDevices.empty()) {
        AppendMenuW(micMenu, MF_SEPARATOR, 0, nullptr);
        for (size_t i = 0; i < micDevices.size() && i < 100; i++) {
            UINT flags = MF_STRING;
            if (micDevices[i].id == selectedMicId) flags |= MF_CHECKED;
            AppendMenuW(micMenu, flags, IDM_MIC_DEVICE + static_cast<UINT>(i),
                        micDevices[i].name.c_str());
        }
    }

    AppendMenuW(menu, MF_STRING | MF_POPUP, reinterpret_cast<UINT_PTR>(micMenu), L"Microphone");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    // Open Config Folder
    AppendMenuW(menu, MF_STRING, IDM_OPEN_CONFIG, L"Open Config Folder...");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    // Launch at Login
    HKEY hKey;
    bool launchAtLogin = false;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run",
                      0, KEY_READ, &hKey) == ERROR_SUCCESS) {
        launchAtLogin = RegQueryValueExW(hKey, L"Koe", nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
        RegCloseKey(hKey);
    }
    AppendMenuW(menu, MF_STRING | (launchAtLogin ? MF_CHECKED : 0),
                IDM_LAUNCH_AT_LOGIN, L"Launch at Login");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    // Quit
    AppendMenuW(menu, MF_STRING, IDM_QUIT, L"Quit Koe");

    // Show menu
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(m_hwnd);
    int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, m_hwnd, nullptr);
    DestroyMenu(menu);

    if (m_delegate) m_delegate->trayMenuDidClose();

    // Handle commands
    switch (cmd) {
    case IDM_OPEN_CONFIG: {
        wchar_t configDir[MAX_PATH];
        DWORD len = GetEnvironmentVariableW(L"APPDATA", configDir, MAX_PATH);
        if (len > 0) {
            wcscat_s(configDir, L"\\koe");
            CreateDirectoryW(configDir, nullptr);
            ShellExecuteW(nullptr, L"open", configDir, nullptr, nullptr, SW_SHOWNORMAL);
        }
        break;
    }
    case IDM_LAUNCH_AT_LOGIN: {
        HKEY hk;
        if (RegOpenKeyExW(HKEY_CURRENT_USER,
                          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run",
                          0, KEY_SET_VALUE | KEY_READ, &hk) == ERROR_SUCCESS) {
            if (launchAtLogin) {
                RegDeleteValueW(hk, L"Koe");
            } else {
                wchar_t exePath[MAX_PATH];
                GetModuleFileNameW(nullptr, exePath, MAX_PATH);
                RegSetValueExW(hk, L"Koe", 0, REG_SZ,
                               reinterpret_cast<const BYTE*>(exePath),
                               static_cast<DWORD>((wcslen(exePath) + 1) * sizeof(wchar_t)));
            }
            RegCloseKey(hk);
        }
        break;
    }
    case IDM_QUIT:
        if (m_delegate) m_delegate->trayDidSelectQuit();
        break;
    case IDM_MIC_DEFAULT:
        if (m_audioDeviceManager) m_audioDeviceManager->setSelectedDeviceId(nullptr);
        if (m_delegate) m_delegate->trayDidSelectAudioDevice(nullptr);
        break;
    default:
        if (cmd >= IDM_MIC_DEVICE && cmd < IDM_MIC_DEVICE + 100) {
            size_t idx = cmd - IDM_MIC_DEVICE;
            if (idx < micDevices.size()) {
                if (m_audioDeviceManager) m_audioDeviceManager->setSelectedDeviceId(micDevices[idx].id.c_str());
                if (m_delegate) m_delegate->trayDidSelectAudioDevice(micDevices[idx].id.c_str());
            }
        }
        break;
    }
}

void TrayManager::setStats(int64_t sessionCount, int64_t totalDurationMs,
                           int64_t totalCharCount, int64_t totalWordCount) {
    m_sessionCount = sessionCount;
    m_totalDurationMs = totalDurationMs;
    m_totalCharCount = totalCharCount;
    m_totalWordCount = totalWordCount;
}

// ── Icon drawing with GDI+ ──────────────────────────────

bool TrayManager::isDarkTaskbar() {
    HKEY hKey;
    DWORD value = 0;
    DWORD size = sizeof(value);
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                      0, KEY_READ, &hKey) == ERROR_SUCCESS) {
        RegQueryValueExW(hKey, L"SystemUsesLightTheme", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(&value), &size);
        RegCloseKey(hKey);
    }
    // value=0 means dark mode, value=1 means light mode
    return value == 0;
}

int TrayManager::getIconSize() {
    // Default to system small icon size
    return GetSystemMetrics(SM_CXSMICON);
}

// Helper: create an HICON from a GDI+ Bitmap
static HICON bitmapToIcon(Bitmap* bmp) {
    HICON hIcon = nullptr;
    bmp->GetHICON(&hIcon);
    return hIcon;
}

HICON TrayManager::drawIdleIcon() {
    int size = getIconSize();
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.Clear(Color(0, 0, 0, 0));

    bool dark = isDarkTaskbar();
    Color fg = dark ? Color(255, 255, 255, 255) : Color(255, 0, 0, 0);
    SolidBrush brush(fg);

    float barWidth = size * 0.11f;
    float spacing = size * 0.14f;
    float centerX = size / 2.0f;
    float centerY = size / 2.0f;
    float heights[] = { 0.22f, 0.39f, 0.61f, 0.39f, 0.22f };
    int barCount = 5;
    float totalWidth = barCount * barWidth + (barCount - 1) * spacing;
    float startX = centerX - totalWidth / 2.0f;

    for (int i = 0; i < barCount; i++) {
        float h = heights[i] * size;
        float x = startX + i * (barWidth + spacing);
        float y = centerY - h / 2.0f;
        g.FillRectangle(&brush, x, y, barWidth, h);
    }

    return bitmapToIcon(&bmp);
}

HICON TrayManager::drawRecordingIcon(int frame) {
    int size = getIconSize();
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.Clear(Color(0, 0, 0, 0));

    bool dark = isDarkTaskbar();
    Color fg = dark ? Color(255, 255, 255, 255) : Color(255, 0, 0, 0);
    int barCount = 5;
    float barWidth = size * 0.11f;
    float spacing = size * 0.14f;
    float centerX = size / 2.0f;
    float centerY = size / 2.0f;
    float totalWidth = barCount * barWidth + (barCount - 1) * spacing;
    float startX = centerX - totalWidth / 2.0f;

    for (int i = 0; i < barCount; i++) {
        double phase = (double)(i + frame) * 0.8;
        float t = static_cast<float>(fabs(sin(phase)));
        float h = (0.22f + 0.50f * t) * size;
        BYTE alpha = static_cast<BYTE>(140 + 115 * t);
        SolidBrush brush(Color(alpha, fg.GetR(), fg.GetG(), fg.GetB()));
        float x = startX + i * (barWidth + spacing);
        float y = centerY - h / 2.0f;
        g.FillRectangle(&brush, x, y, barWidth, h);
    }

    return bitmapToIcon(&bmp);
}

HICON TrayManager::drawProcessingIcon(int frame) {
    int size = getIconSize();
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.Clear(Color(0, 0, 0, 0));

    bool dark = isDarkTaskbar();
    Color fg = dark ? Color(255, 255, 255, 255) : Color(255, 0, 0, 0);
    int dotCount = 3;
    float dotSpacing = size * 0.28f;
    float centerX = size / 2.0f;
    float centerY = size / 2.0f;
    float totalWidth = (dotCount - 1) * dotSpacing;
    float startX = centerX - totalWidth / 2.0f;

    for (int i = 0; i < dotCount; i++) {
        double phase = (double)(frame - i) * 0.7;
        float t = static_cast<float>(fmax(0, sin(phase)));
        float radius = size * (0.08f + 0.08f * t);
        BYTE alpha = static_cast<BYTE>(100 + 155 * t);
        SolidBrush brush(Color(alpha, fg.GetR(), fg.GetG(), fg.GetB()));
        float x = startX + i * dotSpacing;
        g.FillEllipse(&brush, x - radius, centerY - radius, radius * 2, radius * 2);
    }

    return bitmapToIcon(&bmp);
}

HICON TrayManager::drawSuccessIcon() {
    int size = getIconSize();
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.Clear(Color(0, 0, 0, 0));

    bool dark = isDarkTaskbar();
    Color fg = dark ? Color(255, 255, 255, 255) : Color(255, 0, 0, 0);
    Pen pen(fg, size * 0.12f);
    pen.SetLineCap(LineCapRound, LineCapRound, DashCapRound);

    float cx = size / 2.0f;
    float cy = size / 2.0f;
    float s = size * 0.22f;
    PointF points[] = {
        PointF(cx - s, cy),
        PointF(cx - s * 0.15f, cy + s * 0.7f),
        PointF(cx + s * 1.1f, cy - s * 0.8f),
    };
    g.DrawLines(&pen, points, 3);

    return bitmapToIcon(&bmp);
}

HICON TrayManager::drawErrorIcon() {
    int size = getIconSize();
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.Clear(Color(0, 0, 0, 0));

    bool dark = isDarkTaskbar();
    Color fg = dark ? Color(255, 255, 255, 255) : Color(255, 0, 0, 0);
    Pen pen(fg, size * 0.12f);
    pen.SetLineCap(LineCapRound, LineCapRound, DashCapRound);

    float cx = size / 2.0f;
    float cy = size / 2.0f;
    float arm = size * 0.22f;
    g.DrawLine(&pen, cx - arm, cy - arm, cx + arm, cy + arm);
    g.DrawLine(&pen, cx + arm, cy - arm, cx - arm, cy + arm);

    return bitmapToIcon(&bmp);
}

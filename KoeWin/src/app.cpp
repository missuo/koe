#include "app.h"
#include "bridge.h"
#include "audio.h"
#include "clipboard.h"
#include "paste.h"
#include "cue.h"
#include "tray.h"
#include "overlay.h"
#include "history.h"
#include <cstdio>
#include <string>

extern "C" {
#include "koe_core.h"
}

App::App(HWND messageWindow, HINSTANCE hInstance)
    : m_hwnd(messageWindow), m_hInstance(hInstance) {
    QueryPerformanceFrequency(&m_perfFreq);
}

App::~App() {
    delete m_hotkey;
    delete m_overlay;
    delete m_tray;
    delete m_history;
    delete m_cue;
    delete m_paste;
    delete m_clipboard;
    delete m_audio;
    delete m_bridge;
}

void App::initialize() {
    OutputDebugStringA("[Koe] Initializing...\n");

    // Init order matches macOS: cue -> clipboard -> paste -> audio -> bridge -> tray -> overlay -> hotkey
    m_cue = new CuePlayer();
    m_clipboard = new ClipboardManager();
    m_paste = new PasteManager();
    m_audio = new AudioCapture();
    m_history = new HistoryManager();

    m_bridge = new RustBridge(m_hwnd);
    m_bridge->initialize();

    // System tray
    m_tray = new TrayManager(m_hwnd, this);
    m_tray->create();

    // Floating overlay
    m_overlay = new OverlayPanel(m_hInstance);

    // Read hotkey config and start monitor
    SPHotkeyConfig hotkeyConfig = sp_core_get_hotkey_config();
    m_hotkey = new HotkeyMonitor(m_hwnd, this);
    m_hotkey->targetKeyCode = hotkeyConfig.key_code;
    m_hotkey->start();

    // Start config file watcher (3 second interval)
    {
        // Record initial config file modification time
        wchar_t configPath[MAX_PATH];
        DWORD len = GetEnvironmentVariableW(L"APPDATA", configPath, MAX_PATH);
        if (len > 0) {
            wcscat_s(configPath, L"\\koe\\config.yaml");
            WIN32_FILE_ATTRIBUTE_DATA fad;
            if (GetFileAttributesExW(configPath, GetFileExInfoStandard, &fad)) {
                m_lastConfigModTime = fad.ftLastWriteTime;
            }
        }
        SetTimer(m_hwnd, TIMER_CONFIG_WATCH, 3000, nullptr);
    }

    OutputDebugStringA("[Koe] Ready — hotkey monitor active\n");
}

void App::shutdown() {
    OutputDebugStringA("[Koe] Shutting down...\n");
    KillTimer(m_hwnd, TIMER_CONFIG_WATCH);
    if (m_hotkey) m_hotkey->stop();
    if (m_audio) m_audio->stop();
    if (m_tray) m_tray->destroy();
    if (m_bridge) m_bridge->destroy();
}

// ── Config file watcher ─────────────────────────────────

void App::checkConfigFileChanged() {
    wchar_t configPath[MAX_PATH];
    DWORD len = GetEnvironmentVariableW(L"APPDATA", configPath, MAX_PATH);
    if (len == 0) return;
    wcscat_s(configPath, L"\\koe\\config.yaml");

    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(configPath, GetFileExInfoStandard, &fad)) return;

    if (CompareFileTime(&fad.ftLastWriteTime, &m_lastConfigModTime) == 0) return;
    m_lastConfigModTime = fad.ftLastWriteTime;

    OutputDebugStringA("[Koe] Config file changed, reloading...\n");
    m_bridge->reloadConfig();

    // Check if hotkey settings changed
    SPHotkeyConfig newConfig = sp_core_get_hotkey_config();
    if (m_hotkey->targetKeyCode != newConfig.key_code) {
        char buf[128];
        snprintf(buf, sizeof(buf), "[Koe] Hotkey changed: 0x%02X -> 0x%02X\n",
                 m_hotkey->targetKeyCode, newConfig.key_code);
        OutputDebugStringA(buf);

        m_hotkey->stop();
        m_hotkey->targetKeyCode = newConfig.key_code;
        m_hotkey->start();
    }
}

// ── Hotkey message forwarding from WndProc ──────────────

void App::onHotkeyKeyDown() {
    if (m_hotkey) m_hotkey->handleKeyDown();
}

void App::onHotkeyKeyUp() {
    if (m_hotkey) m_hotkey->handleKeyUp();
}

// ── Tray message forwarding from WndProc ────────────────

void App::onTrayMessage(WPARAM wParam, LPARAM lParam) {
    if (m_tray) m_tray->onTrayMessage(wParam, lParam);
}

// ── HotkeyDelegate ──────────────────────────────────────

void App::hotkeyDidDetectHoldStart() {
    OutputDebugStringA("[Koe] Hold start detected\n");
    beginRecording(0);  // SPSessionMode::Hold
}

void App::hotkeyDidDetectHoldEnd() {
    OutputDebugStringA("[Koe] Hold end detected\n");
    endRecording();
}

void App::hotkeyDidDetectTapStart() {
    OutputDebugStringA("[Koe] Tap start detected\n");
    beginRecording(1);  // SPSessionMode::Toggle
}

void App::hotkeyDidDetectTapEnd() {
    OutputDebugStringA("[Koe] Tap end detected\n");
    endRecording();
}

void App::beginRecording(int mode) {
    m_cue->reloadFeedbackConfig();
    m_cue->playStart();

    QueryPerformanceCounter(&m_recordingStartTime);

    m_bridge->beginSession(mode);
    m_audio->start([this](const uint8_t* buffer, uint32_t length, uint64_t timestamp) {
        m_bridge->pushAudio(buffer, length, timestamp);
    });
}

void App::endRecording() {
    m_cue->playStop();
    // 300ms trailing audio delay (matches macOS)
    SetTimer(m_hwnd, TIMER_TRAILING_AUDIO, 300, nullptr);
}

// ── TrayDelegate ────────────────────────────────────────

void App::trayMenuDidOpen() {
    if (m_hotkey) m_hotkey->suspended = true;

    // Refresh stats for menu
    if (m_history && m_tray) {
        HistoryStats stats = m_history->aggregateStats();
        m_tray->setStats(stats.sessionCount, stats.totalDurationMs,
                         stats.totalCharCount, stats.totalWordCount);
    }
}

void App::trayMenuDidClose() {
    if (m_hotkey) m_hotkey->suspended = false;
}

void App::trayDidSelectQuit() {
    PostMessageW(m_hwnd, WM_DESTROY, 0, 0);
}

// ── Timer handler ───────────────────────────────────────

void App::onTimer(UINT_PTR timerId) {
    switch (timerId) {
    case TIMER_TRAILING_AUDIO:
        KillTimer(m_hwnd, timerId);
        m_audio->stop();
        m_bridge->endSession();
        break;

    case TIMER_PASTE_DELAY:
        KillTimer(m_hwnd, timerId);
        m_paste->simulatePaste();
        SetTimer(m_hwnd, TIMER_POST_PASTE, 100, nullptr);
        break;

    case TIMER_POST_PASTE:
        KillTimer(m_hwnd, timerId);
        m_clipboard->scheduleRestore(m_hwnd, 1500);
        break;

    case TIMER_CLIPBOARD_RESTORE:
        KillTimer(m_hwnd, timerId);
        m_clipboard->restoreIfUnchanged();
        break;

    case TIMER_ERROR_RESET:
        KillTimer(m_hwnd, timerId);
        if (m_tray) m_tray->updateState("idle");
        if (m_overlay) m_overlay->updateState("idle");
        break;

    case TIMER_TRAY_ANIM:
        if (m_tray) m_tray->onAnimationTimer();
        break;

    case TIMER_CONFIG_WATCH:
        checkConfigFileChanged();
        break;
    }
}

// ── Rust callback handlers ──────────────────────────────

void App::onSessionReady() {
    OutputDebugStringA("[Koe] Session ready (ASR connected)\n");
}

void App::onSessionError(const wchar_t* message) {
    OutputDebugStringW(L"[Koe] Session error: ");
    OutputDebugStringW(message);
    OutputDebugStringW(L"\n");

    m_cue->playError();
    m_audio->stop();

    if (m_tray) m_tray->updateState("error");
    if (m_overlay) m_overlay->updateState("error");

    // Reset to idle after 2 seconds
    SetTimer(m_hwnd, TIMER_ERROR_RESET, 2000, nullptr);
}

void App::onSessionWarning(const wchar_t* message) {
    OutputDebugStringW(L"[Koe] Session warning: ");
    OutputDebugStringW(message);
    OutputDebugStringW(L"\n");
}

void App::onFinalTextReady(const wchar_t* text) {
    OutputDebugStringW(L"[Koe] Final text: ");
    OutputDebugStringW(text);
    OutputDebugStringW(L"\n");

    // Record history
    if (m_history) {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        int64_t durationMs = 0;
        if (m_recordingStartTime.QuadPart > 0 && m_perfFreq.QuadPart > 0) {
            durationMs = (now.QuadPart - m_recordingStartTime.QuadPart) * 1000 / m_perfFreq.QuadPart;
        }
        m_history->recordSession(durationMs, text);
    }

    if (m_tray) m_tray->updateState("pasting");
    if (m_overlay) m_overlay->updateState("pasting");

    // Backup clipboard -> write text -> paste -> restore
    m_clipboard->backup();
    m_clipboard->writeText(text);

    // 50ms delay before paste (same as macOS)
    SetTimer(m_hwnd, TIMER_PASTE_DELAY, 50, nullptr);
}

void App::onLogEvent(int level, const char* message) {
    const char* levelStr = "???";
    switch (level) {
    case 0: levelStr = "ERROR"; break;
    case 1: levelStr = "WARN"; break;
    case 2: levelStr = "INFO"; break;
    case 3: levelStr = "DEBUG"; break;
    }

    char buf[2048];
    snprintf(buf, sizeof(buf), "[Koe/Rust][%s] %s\n", levelStr, message);
    OutputDebugStringA(buf);
}

void App::onStateChanged(const char* state) {
    char buf[256];
    snprintf(buf, sizeof(buf), "[Koe] State: %s\n", state);
    OutputDebugStringA(buf);

    if (m_tray) m_tray->updateState(state);
    if (m_overlay) m_overlay->updateState(state);
}

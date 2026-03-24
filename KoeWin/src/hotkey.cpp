#include "hotkey.h"
#include <cstdio>

HotkeyMonitor* g_hotkeyMonitor = nullptr;

HotkeyMonitor::HotkeyMonitor(HWND messageWindow, HotkeyDelegate* delegate)
    : m_hwnd(messageWindow), m_delegate(delegate) {}

HotkeyMonitor::~HotkeyMonitor() {
    stop();
}

void HotkeyMonitor::start() {
    if (m_hook) return;

    g_hotkeyMonitor = this;
    m_hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, nullptr, 0);
    if (!m_hook) {
        OutputDebugStringA("[Koe] Failed to install keyboard hook\n");
        return;
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "[Koe] Hotkey monitor started (vk=0x%02X threshold=%.0fms)\n",
             targetKeyCode, holdThresholdMs);
    OutputDebugStringA(buf);
}

void HotkeyMonitor::stop() {
    if (m_hook) {
        UnhookWindowsHookEx(m_hook);
        m_hook = nullptr;
    }
    if (m_holdTimerId) {
        KillTimer(m_hwnd, m_holdTimerId);
        m_holdTimerId = 0;
    }
    m_state = Idle;
    m_keyDown = false;
    if (g_hotkeyMonitor == this) g_hotkeyMonitor = nullptr;
    OutputDebugStringA("[Koe] Hotkey monitor stopped\n");
}

// ── Low-level keyboard hook callback (must return fast) ──

LRESULT CALLBACK HotkeyMonitor::keyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION && g_hotkeyMonitor && !g_hotkeyMonitor->suspended) {
        auto* kbs = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
        if (kbs->vkCode == g_hotkeyMonitor->targetKeyCode) {
            if (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) {
                PostMessageW(g_hotkeyMonitor->m_hwnd, WM_HOTKEY_KEYDOWN, 0, 0);
            } else if (wParam == WM_KEYUP || wParam == WM_SYSKEYUP) {
                PostMessageW(g_hotkeyMonitor->m_hwnd, WM_HOTKEY_KEYUP, 0, 0);
            }
            if (g_hotkeyMonitor->consumeKey) {
                return 1;  // Consume the key — do not pass to other apps
            }
        }
    }
    return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

// ── Hold timer callback ──

void CALLBACK HotkeyMonitor::holdTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD time) {
    if (g_hotkeyMonitor) {
        g_hotkeyMonitor->handleHoldTimer();
    }
}

// ── State machine (runs on main thread) ──

void HotkeyMonitor::handleKeyDown() {
    if (m_keyDown) return;  // Ignore auto-repeat
    m_keyDown = true;

    switch (m_state) {
    case Idle:
        m_state = Pending;
        // Start hold timer
        m_holdTimerId = SetTimer(m_hwnd, 1001, static_cast<UINT>(holdThresholdMs), holdTimerProc);
        break;

    case RecordingToggle:
        m_state = ConsumeKeyUp;
        if (m_delegate) m_delegate->hotkeyDidDetectTapEnd();
        break;

    default:
        break;
    }
}

void HotkeyMonitor::handleKeyUp() {
    if (!m_keyDown) return;
    m_keyDown = false;

    switch (m_state) {
    case Pending:
        // Key released before threshold -> tap
        if (m_holdTimerId) {
            KillTimer(m_hwnd, m_holdTimerId);
            m_holdTimerId = 0;
        }
        m_state = RecordingToggle;
        if (m_delegate) m_delegate->hotkeyDidDetectTapStart();
        break;

    case RecordingHold:
        m_state = Idle;
        if (m_delegate) m_delegate->hotkeyDidDetectHoldEnd();
        break;

    case ConsumeKeyUp:
        m_state = Idle;
        break;

    default:
        break;
    }
}

void HotkeyMonitor::handleHoldTimer() {
    if (m_holdTimerId) {
        KillTimer(m_hwnd, m_holdTimerId);
        m_holdTimerId = 0;
    }
    if (m_state == Pending) {
        m_state = RecordingHold;
        if (m_delegate) m_delegate->hotkeyDidDetectHoldStart();
    }
}

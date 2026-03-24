#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include "app.h"
#include "bridge.h"
#include "hotkey.h"
#include "tray.h"

static App* g_app = nullptr;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    // ── Rust FFI callbacks ──
    case WM_RUST_SESSION_READY:
        if (g_app) g_app->onSessionReady();
        return 0;

    case WM_RUST_SESSION_ERROR: {
        wchar_t* text = reinterpret_cast<wchar_t*>(lParam);
        if (g_app) g_app->onSessionError(text ? text : L"");
        delete[] text;
        return 0;
    }

    case WM_RUST_SESSION_WARNING: {
        wchar_t* text = reinterpret_cast<wchar_t*>(lParam);
        if (g_app) g_app->onSessionWarning(text ? text : L"");
        delete[] text;
        return 0;
    }

    case WM_RUST_FINAL_TEXT: {
        wchar_t* text = reinterpret_cast<wchar_t*>(lParam);
        if (g_app) g_app->onFinalTextReady(text ? text : L"");
        delete[] text;
        return 0;
    }

    case WM_RUST_LOG_EVENT: {
        char* msgUtf8 = reinterpret_cast<char*>(lParam);
        if (g_app) g_app->onLogEvent(static_cast<int>(wParam), msgUtf8 ? msgUtf8 : "");
        delete[] msgUtf8;
        return 0;
    }

    case WM_RUST_STATE_CHANGED: {
        char* state = reinterpret_cast<char*>(lParam);
        if (g_app) g_app->onStateChanged(state ? state : "");
        delete[] state;
        return 0;
    }

    // ── Hotkey keyboard hook messages ──
    case WM_HOTKEY_KEYDOWN:
        if (g_app) g_app->onHotkeyKeyDown();
        return 0;

    case WM_HOTKEY_KEYUP:
        if (g_app) g_app->onHotkeyKeyUp();
        return 0;

    // ── System tray ──
    case WM_TRAY_ICON:
        if (g_app) g_app->onTrayMessage(wParam, lParam);
        return 0;

    // ── Timers ──
    case WM_TIMER:
        if (g_app) g_app->onTimer(wParam);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    // Register window class
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = L"KoeMessageWindow";
    RegisterClassExW(&wc);

    // Create hidden message-only window
    HWND hwnd = CreateWindowExW(
        0, L"KoeMessageWindow", L"Koe", 0,
        0, 0, 0, 0,
        HWND_MESSAGE, nullptr, hInstance, nullptr
    );

    // Initialize application
    App app(hwnd, hInstance);
    g_app = &app;
    app.initialize();

    // Message loop
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    app.shutdown();
    g_app = nullptr;
    CoUninitialize();
    return 0;
}

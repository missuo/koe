#include "bridge.h"
#include <cstring>

extern "C" {
#include "koe_core.h"
}

// Global HWND for PostMessage from Rust callback threads
static HWND g_messageHwnd = nullptr;

// ── Helpers ──────────────────────────────────────────────

// UTF-8 -> heap-allocated wchar_t* (caller owns)
static wchar_t* utf8ToWideHeap(const char* utf8) {
    if (!utf8) return nullptr;
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (len <= 0) return nullptr;
    wchar_t* wide = new wchar_t[len];
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, len);
    return wide;
}

// Heap-allocated char* copy (caller owns)
static char* strDupHeap(const char* src) {
    if (!src) return nullptr;
    size_t len = strlen(src) + 1;
    char* dst = new char[len];
    memcpy(dst, src, len);
    return dst;
}

// ── C callback thunks (called on Rust worker threads) ────

static void on_session_ready() {
    PostMessageW(g_messageHwnd, WM_RUST_SESSION_READY, 0, 0);
}

static void on_session_error(const char* message) {
    PostMessageW(g_messageHwnd, WM_RUST_SESSION_ERROR, 0,
                 reinterpret_cast<LPARAM>(utf8ToWideHeap(message)));
}

static void on_session_warning(const char* message) {
    PostMessageW(g_messageHwnd, WM_RUST_SESSION_WARNING, 0,
                 reinterpret_cast<LPARAM>(utf8ToWideHeap(message)));
}

static void on_final_text_ready(const char* text) {
    PostMessageW(g_messageHwnd, WM_RUST_FINAL_TEXT, 0,
                 reinterpret_cast<LPARAM>(utf8ToWideHeap(text)));
}

static void on_log_event(int level, const char* message) {
    PostMessageW(g_messageHwnd, WM_RUST_LOG_EVENT, static_cast<WPARAM>(level),
                 reinterpret_cast<LPARAM>(strDupHeap(message)));
}

static void on_state_changed(const char* state) {
    PostMessageW(g_messageHwnd, WM_RUST_STATE_CHANGED, 0,
                 reinterpret_cast<LPARAM>(strDupHeap(state)));
}

// ── RustBridge ───────────────────────────────────────────

RustBridge::RustBridge(HWND messageWindow) : m_hwnd(messageWindow) {
    g_messageHwnd = messageWindow;
}

void RustBridge::initialize() {
    SPCallbacks callbacks = {};
    callbacks.on_session_ready = on_session_ready;
    callbacks.on_session_error = on_session_error;
    callbacks.on_session_warning = on_session_warning;
    callbacks.on_final_text_ready = on_final_text_ready;
    callbacks.on_log_event = on_log_event;
    callbacks.on_state_changed = on_state_changed;
    sp_core_register_callbacks(callbacks);

    int32_t result = sp_core_create(nullptr);
    if (result != 0) {
        OutputDebugStringA("[Koe] sp_core_create failed\n");
    }
}

void RustBridge::destroy() {
    sp_core_destroy();
}

void RustBridge::beginSession(int mode) {
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);

    char exePath[MAX_PATH] = {};
    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (proc) {
        DWORD size = MAX_PATH;
        QueryFullProcessImageNameA(proc, 0, exePath, &size);
        CloseHandle(proc);
    }

    SPSessionContext context = {};
    context.mode = static_cast<SPSessionMode>(mode);
    context.frontmost_bundle_id = exePath[0] ? exePath : nullptr;
    context.frontmost_pid = static_cast<int>(pid);

    sp_core_session_begin(context);
}

void RustBridge::pushAudio(const uint8_t* frame, uint32_t len, uint64_t timestamp) {
    sp_core_push_audio(frame, len, timestamp);
}

void RustBridge::endSession() {
    sp_core_session_end();
}

void RustBridge::reloadConfig() {
    sp_core_reload_config();
}

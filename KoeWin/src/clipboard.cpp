#include "clipboard.h"
#include <cstdio>

// Clipboard formats that use special handle types (not HGLOBAL).
// These cannot be backed up with GlobalSize/GlobalLock.
static bool isNonGlobalFormat(UINT format) {
    switch (format) {
    case CF_BITMAP:
    case CF_ENHMETAFILE:
    case CF_METAFILEPICT:
    case CF_PALETTE:
    case CF_OWNERDISPLAY:
    case CF_DSPBITMAP:
    case CF_DSPENHMETAFILE:
    case CF_DSPMETAFILEPICT:
        return true;
    default:
        return false;
    }
}

void ClipboardManager::backup() {
    m_backedUpItems.clear();
    m_backedUpSeqNumber = GetClipboardSequenceNumber();

    if (!OpenClipboard(nullptr)) return;

    UINT format = 0;
    while ((format = EnumClipboardFormats(format)) != 0) {
        if (isNonGlobalFormat(format)) continue;

        HANDLE hData = GetClipboardData(format);
        if (!hData) continue;

        SIZE_T size = GlobalSize(hData);
        if (size == 0) {
            char buf[64];
            snprintf(buf, sizeof(buf),
                     "[Koe] Clipboard: skipping format %u (size=0)\n", format);
            OutputDebugStringA(buf);
            continue;
        }

        void* src = GlobalLock(hData);
        if (!src) continue;

        ClipboardEntry entry;
        entry.format = format;
        entry.data.resize(size);
        memcpy(entry.data.data(), src, size);
        m_backedUpItems.push_back(std::move(entry));

        GlobalUnlock(hData);
    }

    CloseClipboard();
}

void ClipboardManager::writeText(const wchar_t* text) {
    if (!text) return;

    size_t len = wcslen(text);
    size_t bytes = (len + 1) * sizeof(wchar_t);

    HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!hGlobal) return;

    void* dst = GlobalLock(hGlobal);
    memcpy(dst, text, bytes);
    GlobalUnlock(hGlobal);

    if (OpenClipboard(nullptr)) {
        EmptyClipboard();
        SetClipboardData(CF_UNICODETEXT, hGlobal);
        CloseClipboard();
        m_writtenSeqNumber = GetClipboardSequenceNumber();
    } else {
        GlobalFree(hGlobal);
    }
}

void ClipboardManager::scheduleRestore(HWND hwnd, UINT delayMs) {
    if (m_backedUpItems.empty()) return;
    // Timer ID 2001 used for clipboard restore
    SetTimer(hwnd, 2001, delayMs, nullptr);
}

void ClipboardManager::restoreIfUnchanged() {
    DWORD currentSeq = GetClipboardSequenceNumber();
    if (currentSeq != m_writtenSeqNumber) {
        OutputDebugStringA("[Koe] Clipboard changed since write, skipping restore\n");
        return;
    }

    if (m_backedUpItems.empty()) return;

    if (!OpenClipboard(nullptr)) return;
    EmptyClipboard();

    for (const auto& entry : m_backedUpItems) {
        HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, entry.data.size());
        if (!hGlobal) continue;

        void* dst = GlobalLock(hGlobal);
        memcpy(dst, entry.data.data(), entry.data.size());
        GlobalUnlock(hGlobal);

        SetClipboardData(entry.format, hGlobal);
    }

    CloseClipboard();
    m_backedUpItems.clear();
    OutputDebugStringA("[Koe] Clipboard restored\n");
}

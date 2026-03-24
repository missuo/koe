#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <vector>

class ClipboardManager {
public:
    void backup();
    void writeText(const wchar_t* text);
    void scheduleRestore(HWND hwnd, UINT delayMs);
    void restoreIfUnchanged();

private:
    struct ClipboardEntry {
        UINT format;
        std::vector<BYTE> data;
    };

    std::vector<ClipboardEntry> m_backedUpItems;
    DWORD m_backedUpSeqNumber = 0;
    DWORD m_writtenSeqNumber = 0;
};

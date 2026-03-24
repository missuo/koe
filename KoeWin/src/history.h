#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <string>

struct HistoryStats {
    int64_t sessionCount = 0;
    int64_t totalDurationMs = 0;
    int64_t totalCharCount = 0;
    int64_t totalWordCount = 0;
};

class HistoryManager {
public:
    HistoryManager();
    ~HistoryManager();

    void recordSession(int64_t durationMs, const wchar_t* text);
    HistoryStats aggregateStats();

private:
    void openDatabase();
    void countText(const wchar_t* text, int64_t& charCount, int64_t& wordCount);

    struct sqlite3* m_db = nullptr;
};

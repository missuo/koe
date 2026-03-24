#include "history.h"
#include "sqlite3.h"
#include <cstdio>
#include <ctime>

HistoryManager::HistoryManager() {
    openDatabase();
}

HistoryManager::~HistoryManager() {
    if (m_db) {
        sqlite3_close(m_db);
        m_db = nullptr;
    }
}

void HistoryManager::openDatabase() {
    // DB path: %APPDATA%\koe\history.db
    wchar_t appdata[MAX_PATH];
    DWORD len = GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
    if (len == 0) return;

    std::wstring dir = std::wstring(appdata) + L"\\koe";
    CreateDirectoryW(dir.c_str(), nullptr);

    std::wstring dbPathW = dir + L"\\history.db";

    // Convert to UTF-8 for sqlite3_open
    char dbPath[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, dbPathW.c_str(), -1, dbPath, sizeof(dbPath), nullptr, nullptr);

    if (sqlite3_open(dbPath, &m_db) != SQLITE_OK) {
        char buf[512];
        snprintf(buf, sizeof(buf), "[Koe] Failed to open history DB: %s\n", sqlite3_errmsg(m_db));
        OutputDebugStringA(buf);
        m_db = nullptr;
        return;
    }

    const char* sql =
        "CREATE TABLE IF NOT EXISTS sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  timestamp INTEGER NOT NULL,"
        "  duration_ms INTEGER NOT NULL,"
        "  text TEXT NOT NULL,"
        "  char_count INTEGER NOT NULL,"
        "  word_count INTEGER NOT NULL"
        ");";

    char* errMsg = nullptr;
    if (sqlite3_exec(m_db, sql, nullptr, nullptr, &errMsg) != SQLITE_OK) {
        char buf[512];
        snprintf(buf, sizeof(buf), "[Koe] Failed to create sessions table: %s\n", errMsg);
        OutputDebugStringA(buf);
        sqlite3_free(errMsg);
    }
}

void HistoryManager::recordSession(int64_t durationMs, const wchar_t* text) {
    if (!m_db || !text || wcslen(text) == 0) return;

    int64_t charCount = 0, wordCount = 0;
    countText(text, charCount, wordCount);

    // Convert text to UTF-8
    int utf8Len = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    std::string utf8Text(utf8Len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8Text.data(), utf8Len, nullptr, nullptr);

    const char* sql = "INSERT INTO sessions (timestamp, duration_ms, text, char_count, word_count) "
                      "VALUES (?, ?, ?, ?, ?);";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, static_cast<sqlite3_int64>(time(nullptr)));
        sqlite3_bind_int64(stmt, 2, static_cast<sqlite3_int64>(durationMs));
        sqlite3_bind_text(stmt, 3, utf8Text.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 4, static_cast<sqlite3_int64>(charCount));
        sqlite3_bind_int64(stmt, 5, static_cast<sqlite3_int64>(wordCount));

        if (sqlite3_step(stmt) != SQLITE_DONE) {
            char buf[512];
            snprintf(buf, sizeof(buf), "[Koe] Failed to insert session: %s\n", sqlite3_errmsg(m_db));
            OutputDebugStringA(buf);
        }
    }
    sqlite3_finalize(stmt);

    char buf[256];
    snprintf(buf, sizeof(buf), "[Koe] History recorded — duration:%lldms chars:%lld words:%lld\n",
             durationMs, charCount, wordCount);
    OutputDebugStringA(buf);
}

HistoryStats HistoryManager::aggregateStats() {
    HistoryStats stats;
    if (!m_db) return stats;

    const char* sql = "SELECT COUNT(*), COALESCE(SUM(duration_ms),0), "
                      "COALESCE(SUM(char_count),0), COALESCE(SUM(word_count),0) "
                      "FROM sessions;";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            stats.sessionCount = sqlite3_column_int64(stmt, 0);
            stats.totalDurationMs = sqlite3_column_int64(stmt, 1);
            stats.totalCharCount = sqlite3_column_int64(stmt, 2);
            stats.totalWordCount = sqlite3_column_int64(stmt, 3);
        }
    }
    sqlite3_finalize(stmt);

    return stats;
}

// Same CJK/Latin counting logic as macOS SPHistoryManager
void HistoryManager::countText(const wchar_t* text, int64_t& charCount, int64_t& wordCount) {
    charCount = 0;
    wordCount = 0;
    bool inWord = false;

    for (size_t i = 0; text[i]; i++) {
        wchar_t ch = text[i];

        // CJK Unified Ideographs and extensions
        if ((ch >= 0x4E00 && ch <= 0x9FFF) ||
            (ch >= 0x3400 && ch <= 0x4DBF) ||
            (ch >= 0xF900 && ch <= 0xFAFF)) {
            charCount++;
            if (inWord) {
                wordCount++;
                inWord = false;
            }
        } else if ((ch >= L'A' && ch <= L'Z') || (ch >= L'a' && ch <= L'z') ||
                   (ch >= L'0' && ch <= L'9') || ch == L'\'') {
            if (!inWord) inWord = true;
        } else {
            if (inWord) {
                wordCount++;
                inWord = false;
            }
        }
    }
    if (inWord) wordCount++;
}

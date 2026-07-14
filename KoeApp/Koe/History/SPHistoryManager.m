#import "SPHistoryManager.h"
#import <sqlite3.h>

@implementation SPHistoryStats
@end

@interface SPHistoryManager () {
    sqlite3 *_db;
}
@end

@implementation SPHistoryManager

+ (instancetype)sharedManager {
    static SPHistoryManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPHistoryManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    NSString *dir = [NSString stringWithFormat:@"%@/.koe", NSHomeDirectory()];
    return [self initWithDatabasePath:[dir stringByAppendingPathComponent:@"history.db"]];
}

- (instancetype)initWithDatabasePath:(NSString *)dbPath {
    self = [super init];
    if (self) {
        [self openDatabaseAtPath:dbPath];
    }
    return self;
}

- (void)openDatabaseAtPath:(NSString *)dbPath {
    [[NSFileManager defaultManager] createDirectoryAtPath:dbPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    if (sqlite3_open(dbPath.UTF8String, &_db) != SQLITE_OK) {
        NSLog(@"[Koe] Failed to open history database: %s", sqlite3_errmsg(_db));
        _db = NULL;
        return;
    }

    const char *sql =
        "CREATE TABLE IF NOT EXISTS sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  timestamp INTEGER NOT NULL,"
        "  duration_ms INTEGER NOT NULL,"
        "  text TEXT NOT NULL,"
        "  char_count INTEGER NOT NULL,"
        "  word_count INTEGER NOT NULL"
        ");";

    char *errMsg = NULL;
    if (sqlite3_exec(_db, sql, NULL, NULL, &errMsg) != SQLITE_OK) {
        NSLog(@"[Koe] Failed to create sessions table: %s", errMsg);
        sqlite3_free(errMsg);
    }

    [self migrateSchema];
}

/// Add columns introduced after the initial release. Databases created before
/// the migration lack them; ALTER TABLE is a no-op-safe way to catch up.
/// `asr_text` / `asr_provider` stay NULL for sessions recorded before the
/// upgrade — downstream consumers (dictionary suggestions) must skip those.
- (void)migrateSchema {
    NSSet<NSString *> *existing = [self sessionColumnNames];

    NSDictionary<NSString *, NSString *> *wanted = @{
        @"asr_text" : @"TEXT",
        @"asr_provider" : @"TEXT",
        @"llm_applied" : @"INTEGER NOT NULL DEFAULT 0",
        @"processed_for_dictionary" : @"INTEGER NOT NULL DEFAULT 0",
    };

    for (NSString *column in wanted) {
        if ([existing containsObject:column]) continue;

        NSString *alter = [NSString stringWithFormat:@"ALTER TABLE sessions ADD COLUMN %@ %@;",
                           column, wanted[column]];
        char *errMsg = NULL;
        if (sqlite3_exec(_db, alter.UTF8String, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"[Koe] Failed to add column %@: %s", column, errMsg);
            sqlite3_free(errMsg);
        } else {
            NSLog(@"[Koe] History schema migrated: added column %@", column);
        }
    }
}

- (NSSet<NSString *> *)sessionColumnNames {
    NSMutableSet<NSString *> *columns = [NSMutableSet set];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, "PRAGMA table_info(sessions);", -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(stmt, 1);
            if (name) [columns addObject:[NSString stringWithUTF8String:name]];
        }
    }
    sqlite3_finalize(stmt);
    return columns;
}

- (void)recordSessionWithDurationMs:(NSInteger)durationMs
                               text:(NSString *)text
                            asrText:(NSString *)asrText
                        asrProvider:(NSString *)asrProvider
                         llmApplied:(BOOL)llmApplied {
    if (!_db || text.length == 0) return;

    NSInteger charCount = 0;
    NSInteger wordCount = 0;
    [self countText:text charCount:&charCount wordCount:&wordCount];

    const char *sql = "INSERT INTO sessions (timestamp, duration_ms, text, char_count, word_count, "
                      "asr_text, asr_provider, llm_applied) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?);";
    sqlite3_stmt *stmt = NULL;

    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, (sqlite3_int64)[[NSDate date] timeIntervalSince1970]);
        sqlite3_bind_int64(stmt, 2, (sqlite3_int64)durationMs);
        sqlite3_bind_text(stmt, 3, text.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 4, (sqlite3_int64)charCount);
        sqlite3_bind_int64(stmt, 5, (sqlite3_int64)wordCount);
        if (asrText.length > 0) {
            sqlite3_bind_text(stmt, 6, asrText.UTF8String, -1, SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_null(stmt, 6);
        }
        if (asrProvider.length > 0) {
            sqlite3_bind_text(stmt, 7, asrProvider.UTF8String, -1, SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_null(stmt, 7);
        }
        sqlite3_bind_int(stmt, 8, llmApplied ? 1 : 0);

        if (sqlite3_step(stmt) != SQLITE_DONE) {
            NSLog(@"[Koe] Failed to insert session: %s", sqlite3_errmsg(_db));
        }
    }
    sqlite3_finalize(stmt);

    NSLog(@"[Koe] History recorded — duration:%ldms chars:%ld words:%ld provider:%@ llm:%d",
          (long)durationMs, (long)charCount, (long)wordCount,
          asrProvider.length > 0 ? asrProvider : @"?", llmApplied ? 1 : 0);
}

- (void)countText:(NSString *)text charCount:(NSInteger *)outChars wordCount:(NSInteger *)outWords {
    NSInteger chars = 0;
    NSInteger words = 0;
    BOOL inWord = NO;

    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];

        // CJK Unified Ideographs and extensions
        if ((ch >= 0x4E00 && ch <= 0x9FFF) ||   // CJK Unified
            (ch >= 0x3400 && ch <= 0x4DBF) ||   // CJK Extension A
            (ch >= 0xF900 && ch <= 0xFAFF)) {   // CJK Compatibility
            chars++;
            if (inWord) {
                words++;
                inWord = NO;
            }
        } else if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                   (ch >= '0' && ch <= '9') || ch == '\'') {
            // Latin alphanumeric — part of a word
            if (!inWord) {
                inWord = YES;
            }
        } else {
            // Whitespace, punctuation, etc.
            if (inWord) {
                words++;
                inWord = NO;
            }
        }
    }
    if (inWord) {
        words++;
    }

    *outChars = chars;
    *outWords = words;
}

- (SPHistoryStats *)aggregateStats {
    SPHistoryStats *stats = [[SPHistoryStats alloc] init];
    if (!_db) return stats;

    const char *sql = "SELECT COUNT(*), COALESCE(SUM(duration_ms),0), "
                      "COALESCE(SUM(char_count),0), COALESCE(SUM(word_count),0) "
                      "FROM sessions;";
    sqlite3_stmt *stmt = NULL;

    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            stats.sessionCount = (NSInteger)sqlite3_column_int64(stmt, 0);
            stats.totalDurationMs = (NSInteger)sqlite3_column_int64(stmt, 1);
            stats.totalCharCount = (NSInteger)sqlite3_column_int64(stmt, 2);
            stats.totalWordCount = (NSInteger)sqlite3_column_int64(stmt, 3);
        }
    }
    sqlite3_finalize(stmt);

    return stats;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

@end

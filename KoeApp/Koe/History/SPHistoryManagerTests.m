#import <XCTest/XCTest.h>
#import <sqlite3.h>
#import "SPHistoryManager.h"

@interface SPHistoryManagerTests : XCTestCase
@property (nonatomic, copy) NSString *dbPath;
@end

@implementation SPHistoryManagerTests

- (void)setUp {
    [super setUp];
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"koe-history-tests-%@",
                                        NSUUID.UUID.UUIDString]];
    self.dbPath = [dir stringByAppendingPathComponent:@"history.db"];
}

- (void)tearDown {
    [[NSFileManager defaultManager]
        removeItemAtPath:self.dbPath.stringByDeletingLastPathComponent error:nil];
    [super tearDown];
}

// ─── Helpers ────────────────────────────────────────────────────────

- (void)createLegacySchemaDatabase {
    [[NSFileManager defaultManager]
              createDirectoryAtPath:self.dbPath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.dbPath.UTF8String, &db), SQLITE_OK);
    const char *sql =
        "CREATE TABLE sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  timestamp INTEGER NOT NULL,"
        "  duration_ms INTEGER NOT NULL,"
        "  text TEXT NOT NULL,"
        "  char_count INTEGER NOT NULL,"
        "  word_count INTEGER NOT NULL"
        ");"
        "INSERT INTO sessions (timestamp, duration_ms, text, char_count, word_count) "
        "VALUES (1752000000, 1200, 'legacy row', 0, 2);";
    XCTAssertEqual(sqlite3_exec(db, sql, NULL, NULL, NULL), SQLITE_OK);
    sqlite3_close(db);
}

- (NSArray<NSDictionary *> *)allRows {
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.dbPath.UTF8String, &db), SQLITE_OK);
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT text, asr_text, asr_provider, llm_applied, "
                      "processed_for_dictionary FROM sessions ORDER BY id;";
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, NULL), SQLITE_OK);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *text = (const char *)sqlite3_column_text(stmt, 0);
        const char *asrText = (const char *)sqlite3_column_text(stmt, 1);
        const char *provider = (const char *)sqlite3_column_text(stmt, 2);
        [rows addObject:@{
            @"text" : text ? @(text) : NSNull.null,
            @"asr_text" : asrText ? @(asrText) : NSNull.null,
            @"asr_provider" : provider ? @(provider) : NSNull.null,
            @"llm_applied" : @(sqlite3_column_int(stmt, 3)),
            @"processed_for_dictionary" : @(sqlite3_column_int(stmt, 4)),
        }];
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rows;
}

// ─── Tests ──────────────────────────────────────────────────────────

- (void)testFreshDatabaseRecordsSessionWithMetadata {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:900
                                    text:@"Anthropic released a model"
                                 asrText:@"and tropic released a model"
                             asrProvider:@"doubaoime"
                              llmApplied:YES];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqualObjects(rows[0][@"text"], @"Anthropic released a model");
    XCTAssertEqualObjects(rows[0][@"asr_text"], @"and tropic released a model");
    XCTAssertEqualObjects(rows[0][@"asr_provider"], @"doubaoime");
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @1);
    XCTAssertEqualObjects(rows[0][@"processed_for_dictionary"], @0);
}

- (void)testNilMetadataIsStoredAsNull {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:500
                                    text:@"plain"
                                 asrText:nil
                             asrProvider:nil
                              llmApplied:NO];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqualObjects(rows[0][@"asr_text"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"asr_provider"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @0);
}

- (void)testLegacyDatabaseIsMigratedInPlace {
    [self createLegacySchemaDatabase];

    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:800
                                    text:@"new row"
                                 asrText:@"nu row"
                             asrProvider:@"qwen"
                              llmApplied:YES];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 2u);
    // Legacy row survives with NULL/default metadata
    XCTAssertEqualObjects(rows[0][@"text"], @"legacy row");
    XCTAssertEqualObjects(rows[0][@"asr_text"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"asr_provider"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @0);
    // New row carries full metadata
    XCTAssertEqualObjects(rows[1][@"asr_text"], @"nu row");
    XCTAssertEqualObjects(rows[1][@"asr_provider"], @"qwen");
    XCTAssertEqualObjects(rows[1][@"llm_applied"], @1);
}

- (void)testMigrationIsIdempotent {
    [self createLegacySchemaDatabase];
    (void)[[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    // Re-opening an already-migrated database must not fail or duplicate columns
    SPHistoryManager *again = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    XCTAssertNotNil([again aggregateStats]);
    XCTAssertEqual([self allRows].count, 1u);
}

@end

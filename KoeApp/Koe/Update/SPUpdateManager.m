#import "SPUpdateManager.h"
#import "SPLocalization.h"

static NSString * const kSPUpdateLastCheckDateKey = @"SPUpdateLastCheckDate";
static NSString * const kSPUpdateSkippedVersionKey = @"SPUpdateSkippedVersion";
static NSTimeInterval const kSPAutomaticUpdateCheckInterval = 6 * 60 * 60;
static NSTimeInterval const kSPInitialAutomaticCheckDelay = 8.0;

@interface SPUpdateManager ()

@property (nonatomic, strong) NSBundle *bundle;
@property (nonatomic, strong, nullable) NSURL *feedURL;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSTimer *periodicCheckTimer;
@property (nonatomic, assign) BOOL isChecking;

@end

@implementation SPUpdateManager

- (instancetype)initWithBundle:(NSBundle *)bundle {
    self = [super init];
    if (self) {
        _bundle = bundle;

        NSString *feedURLString = [bundle objectForInfoDictionaryKey:@"SPUpdateFeedURL"];
        if ([feedURLString isKindOfClass:[NSString class]] && feedURLString.length > 0) {
            _feedURL = [NSURL URLWithString:feedURLString];
        }

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.timeoutIntervalForResource = 30.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)start {
    if (!self.feedURL) {
        NSLog(@"[Koe] App updates disabled: missing SPUpdateFeedURL");
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPInitialAutomaticCheckDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf performAutomaticCheckIfNeeded];
    });

    self.periodicCheckTimer = [NSTimer scheduledTimerWithTimeInterval:kSPAutomaticUpdateCheckInterval
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
        [weakSelf checkForUpdatesUserInitiated:NO];
    }];
}

- (void)checkForUpdatesFromUserAction {
    [self checkForUpdatesUserInitiated:YES];
}

- (void)performAutomaticCheckIfNeeded {
    NSDate *lastCheckDate = [[NSUserDefaults standardUserDefaults] objectForKey:kSPUpdateLastCheckDateKey];
    if (lastCheckDate && [[NSDate date] timeIntervalSinceDate:lastCheckDate] < kSPAutomaticUpdateCheckInterval) {
        return;
    }
    [self checkForUpdatesUserInitiated:NO];
}

- (void)checkForUpdatesUserInitiated:(BOOL)userInitiated {
    if (!self.feedURL) {
        if (userInitiated) {
            [self showAlertWithTitle:KoeLocalizedString(@"update.unavailable.title")
                     informativeText:KoeLocalizedString(@"update.unavailable.message")
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    if (self.isChecking) {
        if (userInitiated) {
            [self showAlertWithTitle:KoeLocalizedString(@"update.checking.title")
                     informativeText:KoeLocalizedString(@"update.checking.message")
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    self.isChecking = YES;
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kSPUpdateLastCheckDateKey];

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:self.feedURL
                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isChecking = NO;
            [self handleUpdateResponseData:data response:response error:error userInitiated:userInitiated];
        });
    }];
    [task resume];
}

- (void)handleUpdateResponseData:(NSData *)data
                        response:(NSURLResponse *)response
                           error:(NSError *)error
                   userInitiated:(BOOL)userInitiated {
    if (error) {
        NSLog(@"[Koe] Update check failed: %@", error.localizedDescription);
        if (userInitiated) {
            [self showAlertWithTitle:KoeLocalizedString(@"update.failed.title")
                     informativeText:error.localizedDescription ?: KoeLocalizedString(@"update.failed.title")
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]] && httpResponse.statusCode >= 400) {
        NSString *message = [NSString stringWithFormat:KoeLocalizedString(@"update.failed.http"), (long)httpResponse.statusCode];
        NSLog(@"[Koe] Update check failed: %@", message);
        if (userInitiated) {
            [self showAlertWithTitle:KoeLocalizedString(@"update.failed.title")
                     informativeText:message
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    NSError *parseError = nil;
    NSDictionary *feed = [self parsedFeedDictionaryFromData:data error:&parseError];
    if (!feed) {
        NSLog(@"[Koe] Update feed parse failed: %@", parseError.localizedDescription);
        if (userInitiated) {
            [self showAlertWithTitle:KoeLocalizedString(@"update.invalidFeed.title")
                     informativeText:parseError.localizedDescription ?: KoeLocalizedString(@"update.invalidFeed.title")
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    NSString *feedVersion = feed[@"version"];
    NSInteger feedBuild = [self integerValueFromObject:feed[@"build"]];
    NSString *downloadURLString = feed[@"download_url"];
    NSString *minimumSystemVersion = feed[@"minimum_system_version"];

    if (minimumSystemVersion.length > 0 &&
        [self compareVersionString:[self currentSystemVersionString] toVersionString:minimumSystemVersion] == NSOrderedAscending) {
        if (userInitiated) {
            NSString *message = [NSString stringWithFormat:KoeLocalizedString(@"update.notCompatible.message"), feedVersion, minimumSystemVersion];
            [self showAlertWithTitle:KoeLocalizedString(@"update.notCompatible.title")
                     informativeText:message
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    if (![self isFeedVersion:feedVersion build:feedBuild newerThanCurrentVersion:[self currentAppVersionString]
                       build:[self currentAppBuildNumber]]) {
        if (userInitiated) {
            NSString *message = [NSString stringWithFormat:KoeLocalizedString(@"update.upToDate.message"),
                                 [self currentAppVersionString], (long)[self currentAppBuildNumber]];
            [self showAlertWithTitle:KoeLocalizedString(@"update.upToDate.title")
                     informativeText:message
                           buttonOne:KoeLocalizedString(@"update.button.ok")
                           buttonTwo:nil
                         buttonThree:nil
                             handler:nil];
        }
        return;
    }

    NSString *skippedVersion = [[NSUserDefaults standardUserDefaults] stringForKey:kSPUpdateSkippedVersionKey];
    NSString *skipToken = [self skipTokenForVersion:feedVersion build:feedBuild];
    if (!userInitiated && skippedVersion && [skippedVersion isEqualToString:skipToken]) {
        return;
    }

    [self presentUpdateAlertForFeed:feed
                     downloadURLString:downloadURLString
                             skipToken:skipToken
                         userInitiated:userInitiated];
}

- (NSDictionary *)parsedFeedDictionaryFromData:(NSData *)data error:(NSError **)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPUpdateManager"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"The update feed was empty."}];
        }
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"SPUpdateManager"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"The update feed must be a JSON object."}];
        }
        return nil;
    }

    NSDictionary *feed = (NSDictionary *)object;
    NSString *version = [self stringValueFromObject:feed[@"version"]];
    NSString *downloadURLString = [self stringValueFromObject:feed[@"download_url"]];
    if (version.length == 0 || downloadURLString.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPUpdateManager"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"The update feed must include version and download_url."}];
        }
        return nil;
    }

    NSURL *downloadURL = [NSURL URLWithString:downloadURLString];
    if (!downloadURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPUpdateManager"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"The update feed download_url is invalid."}];
        }
        return nil;
    }

    return feed;
}

- (void)presentUpdateAlertForFeed:(NSDictionary *)feed
                downloadURLString:(NSString *)downloadURLString
                        skipToken:(NSString *)skipToken
                    userInitiated:(BOOL)userInitiated {
    NSString *feedVersion = feed[@"version"];
    NSInteger feedBuild = [self integerValueFromObject:feed[@"build"]];
    NSString *notesText = [self notesTextFromFeed:feed];

    NSMutableString *message = [NSMutableString stringWithFormat:KoeLocalizedString(@"update.available.message"),
                                feedVersion];
    if (feedBuild > 0) {
        [message appendFormat:KoeLocalizedString(@"update.available.buildSuffix"), (long)feedBuild];
    }
    [message appendFormat:KoeLocalizedString(@"update.available.body"),
     [self currentAppVersionString], (long)[self currentAppBuildNumber]];
    if (notesText.length > 0) {
        [message appendFormat:@"\n\n%@", notesText];
    }

    NSString *thirdButton = userInitiated ? nil : KoeLocalizedString(@"update.button.skip");
    [self showAlertWithTitle:KoeLocalizedString(@"update.available.title")
             informativeText:message
                   buttonOne:KoeLocalizedString(@"update.button.download")
                   buttonTwo:KoeLocalizedString(@"update.button.later")
                 buttonThree:thirdButton
                     handler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            NSURL *downloadURL = [NSURL URLWithString:downloadURLString];
            if (downloadURL) {
                [[NSWorkspace sharedWorkspace] openURL:downloadURL];
            }
            return;
        }

        if (!userInitiated && thirdButton && response == NSAlertThirdButtonReturn) {
            [[NSUserDefaults standardUserDefaults] setObject:skipToken forKey:kSPUpdateSkippedVersionKey];
        }
    }];
}

- (void)showAlertWithTitle:(NSString *)title
           informativeText:(NSString *)informativeText
                 buttonOne:(NSString *)buttonOne
                 buttonTwo:(nullable NSString *)buttonTwo
               buttonThree:(nullable NSString *)buttonThree
                   handler:(void (^ _Nullable)(NSModalResponse response))handler {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = title;
    alert.informativeText = informativeText;
    [alert addButtonWithTitle:buttonOne];
    if (buttonTwo.length > 0) {
        [alert addButtonWithTitle:buttonTwo];
    }
    if (buttonThree.length > 0) {
        [alert addButtonWithTitle:buttonThree];
    }

    NSModalResponse response = [alert runModal];
    if (handler) {
        handler(response);
    }
}

- (NSString *)notesTextFromFeed:(NSDictionary *)feed {
    id notesObject = feed[@"notes"];
    if ([notesObject isKindOfClass:[NSString class]]) {
        return (NSString *)notesObject;
    }

    if ([notesObject isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (id object in (NSArray *)notesObject) {
            NSString *line = [self stringValueFromObject:object];
            if (line.length > 0) {
                [lines addObject:[NSString stringWithFormat:@"- %@", line]];
            }
        }
        return [lines componentsJoinedByString:@"\n"];
    }

    return @"";
}

- (NSString *)currentAppVersionString {
    NSString *version = [self.bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"0";
}

- (NSInteger)currentAppBuildNumber {
    id buildObject = [self.bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [self integerValueFromObject:buildObject];
}

- (NSString *)currentSystemVersionString {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)version.majorVersion,
            (long)version.minorVersion,
            (long)version.patchVersion];
}

- (BOOL)isFeedVersion:(NSString *)feedVersion
                build:(NSInteger)feedBuild
newerThanCurrentVersion:(NSString *)currentVersion
                build:(NSInteger)currentBuild {
    NSComparisonResult versionComparison = [self compareVersionString:feedVersion toVersionString:currentVersion];
    if (versionComparison == NSOrderedDescending) {
        return YES;
    }
    if (versionComparison == NSOrderedAscending) {
        return NO;
    }
    return feedBuild > currentBuild;
}

- (NSComparisonResult)compareVersionString:(NSString *)left toVersionString:(NSString *)right {
    return [left compare:right options:NSNumericSearch];
}

- (NSString *)skipTokenForVersion:(NSString *)version build:(NSInteger)build {
    return [NSString stringWithFormat:@"%@:%ld", version, (long)build];
}

- (NSString *)stringValueFromObject:(id)object {
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString *)object;
    }
    if ([object respondsToSelector:@selector(stringValue)]) {
        return [object stringValue];
    }
    return @"";
}

- (NSInteger)integerValueFromObject:(id)object {
    if ([object isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)object integerValue];
    }
    if ([object isKindOfClass:[NSString class]]) {
        return [(NSString *)object integerValue];
    }
    return 0;
}

- (void)dealloc {
    [self.periodicCheckTimer invalidate];
    [self.session invalidateAndCancel];
}

@end

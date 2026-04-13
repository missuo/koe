#import "SPLocalization.h"

NSString *const SPLocalizationLanguageKey = @"KoeInterfaceLanguage";
NSNotificationName const SPLocalizationLanguageDidChangeNotification = @"SPLocalizationLanguageDidChange";

@implementation SPLocalization

static NSBundle *_cachedBundle = nil;
static NSString *_cachedLanguage = nil;

+ (NSBundle *)localizedBundle {
    @synchronized (self) {
        if (_cachedBundle) return _cachedBundle;

        NSString *language = [self effectiveLanguage];
        _cachedBundle = [self bundleForLanguage:language];
        return _cachedBundle;
    }
}

+ (NSString *)effectiveLanguage {
    @synchronized (self) {
        if (_cachedLanguage) return _cachedLanguage;

        NSString *preferred = [[NSUserDefaults standardUserDefaults] stringForKey:SPLocalizationLanguageKey];

        if (!preferred || preferred.length == 0 ||
            [preferred caseInsensitiveCompare:@"system"] == NSOrderedSame) {
            _cachedLanguage = [self resolveSystemLanguage];
        } else {
            _cachedLanguage = [self validateLanguage:preferred] ? preferred : @"en";
        }
        return _cachedLanguage;
    }
}

+ (BOOL)isFollowingSystem {
    NSString *preferred = [[NSUserDefaults standardUserDefaults] stringForKey:SPLocalizationLanguageKey];
    return (!preferred || preferred.length == 0 ||
            [preferred caseInsensitiveCompare:@"system"] == NSOrderedSame);
}

+ (void)setPreferredLanguage:(nullable NSString *)languageCode {
    if (!languageCode || languageCode.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:SPLocalizationLanguageKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:languageCode forKey:SPLocalizationLanguageKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self invalidateCache];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPLocalizationLanguageDidChangeNotification
                                                        object:nil];
}

+ (void)invalidateCache {
    @synchronized (self) {
        _cachedBundle = nil;
        _cachedLanguage = nil;
    }
}

+ (NSString *)localizedStringForKey:(NSString *)key {
    return NSLocalizedStringFromTableInBundle(key, nil, [self localizedBundle], nil);
}

#pragma mark - Private

+ (NSString *)resolveSystemLanguage {
    NSArray<NSString *> *preferred = [NSBundle mainBundle].preferredLocalizations;
    if (preferred.count > 0) {
        NSString *lang = preferred.firstObject;
        if ([self validateLanguage:lang]) return lang;
    }
    return @"en";
}

+ (BOOL)validateLanguage:(NSString *)language {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"Localizable"
                                                    ofType:@"strings"
                                               inDirectory:nil
                                           forLocalization:language];
    if (path) return YES;

    // Also check for .xcstrings-derived bundles
    NSString *lproj = [NSString stringWithFormat:@"%@.lproj", language];
    NSString *lprojPath = [[NSBundle mainBundle] pathForResource:lproj ofType:nil];
    return lprojPath != nil;
}

+ (NSBundle *)bundleForLanguage:(NSString *)language {
    NSString *path = [[NSBundle mainBundle] pathForResource:language ofType:@"lproj"];
    if (path) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle) return bundle;
    }
    // Fallback to main bundle (which uses the development language, en)
    return [NSBundle mainBundle];
}

@end

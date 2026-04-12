#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// User-facing language preference stored in NSUserDefaults.
/// - nil / empty / "system" → follow macOS system language
/// - "en" → force English
/// - "zh-Hans" → force Simplified Chinese
extern NSString *const SPLocalizationLanguageKey;

/// Posted when the user changes the interface language in settings.
/// Observers should refresh any cached localized strings.
extern NSNotificationName const SPLocalizationLanguageDidChangeNotification;

/// Returns a localized string for the given key using the user's language
/// preference. Falls back to English if the preferred language is not
/// available in the app bundle.
///
/// Usage:  KoeLocalizedString(@"statusBar.menu.quit")
#define KoeLocalizedString(key) [SPLocalization localizedStringForKey:(key)]

/// Convenience macro with a comment (ignored at runtime, useful for
/// extraction tools and translators).
#define KoeLocalizedStringWithComment(key, comment) [SPLocalization localizedStringForKey:(key)]

@interface SPLocalization : NSObject

/// Returns the localized string for the given key, respecting the user's
/// language preference stored in NSUserDefaults.
+ (NSString *)localizedStringForKey:(NSString *)key;

/// Returns the NSBundle for the user's preferred language.
/// Re-evaluated each time the preference changes.
+ (NSBundle *)localizedBundle;

/// Returns the current effective language code ("en", "zh-Hans", etc.).
+ (NSString *)effectiveLanguage;

/// Returns YES if the current preference is "follow system".
+ (BOOL)isFollowingSystem;

/// Sets the user's language preference and posts
/// SPLocalizationLanguageDidChangeNotification.
/// Pass nil or "system" to revert to follow-system.
+ (void)setPreferredLanguage:(nullable NSString *)languageCode;

/// Invalidates the cached bundle so the next call to localizedBundle
/// re-resolves the language. Called automatically when the preference
/// changes.
+ (void)invalidateCache;

@end

NS_ASSUME_NONNULL_END

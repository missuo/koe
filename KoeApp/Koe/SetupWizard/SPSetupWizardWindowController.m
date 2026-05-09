#import "SPSetupWizardWindowController.h"
#import "SPOverlayPanel.h"
#import "SPRustBridge.h"
#import "SPLocalization.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <Speech/Speech.h>

// Apple Speech asset management FFI (KoeAppleSpeech Swift package)
extern int32_t koe_apple_speech_is_available(void);
extern int32_t koe_apple_speech_asset_status(const char *locale);
extern void koe_apple_speech_install_asset(
    const char *locale,
    void (*callback)(void *ctx, int32_t event_type, const char *text),
    void *ctx
);
extern int32_t koe_apple_speech_release_asset(const char *locale);
extern uint8_t *koe_apple_speech_supported_locales(uint32_t *outLen);

static NSString *const kConfigDir = @".koe";
static NSString *const kDictionaryFile = @"dictionary.txt";
static NSString *const kSystemPromptFile = @"system_prompt.txt";
static NSString *const kTemplateEditablePromptKey = @"__editable_prompt";
static NSString *const kTemplateOriginalPromptKey = @"__original_prompt";
static NSString *const kDefaultLlmChatCompletionsPath = @"/chat/completions";
static NSString *const kOverlayFontFamilyDefault = @"system";
static NSString *const kOverlayFontFamilySystemLabel = @"System Default";
static const NSInteger kOverlayFontSizeDefault = 13;
static const NSInteger kOverlayFontSizeMin = 12;
static const NSInteger kOverlayFontSizeMax = 28;
static const NSInteger kOverlayBottomMarginDefault = 10;
static const NSInteger kOverlayBottomMarginMax = 180;
static const BOOL kOverlayLimitVisibleLinesDefault = YES;
static const NSInteger kOverlayMaxVisibleLinesDefault = 3;
static const NSInteger kOverlayMaxVisibleLinesMin = 3;
static const NSInteger kOverlayMaxVisibleLinesMax = 5;
static NSString *const kOverlayPreviewSampleText = @"刚试了一下这个语音输入，感觉还挺好用的，说完话自动就把文字整理好了，标点符号也帮你加上了，比打字快多了哈哈。";

// Toolbar item identifiers
static NSToolbarItemIdentifier const kToolbarASR = @"asr";
static NSToolbarItemIdentifier const kToolbarLLM = @"llm";
static NSToolbarItemIdentifier const kToolbarOverlay = @"overlay";
static NSToolbarItemIdentifier const kToolbarHotkey = @"hotkey";
static NSToolbarItemIdentifier const kToolbarDictionary = @"dictionary";
static NSToolbarItemIdentifier const kToolbarSystemPrompt = @"system_prompt";
static NSToolbarItemIdentifier const kToolbarTemplates = @"templates";
static NSToolbarItemIdentifier const kToolbarAbout = @"about";

// ─── Config helpers (backed by sp_config_get / sp_config_set) ───────
#import "koe_core.h"

static NSString *configDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:kConfigDir];
}

static NSString *configFilePath(void) {
    return [configDirPath() stringByAppendingPathComponent:@"config.yaml"];
}

static BOOL restoreConfigSnapshot(NSString *snapshot, BOOL existed, NSError **error) {
    NSString *path = configFilePath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (!existed) {
        if (![fileManager fileExistsAtPath:path]) return YES;
        return [fileManager removeItemAtPath:path error:error];
    }

    return [(snapshot ?: @"") writeToFile:path
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:error];
}


static NSString *configGet(NSString *keyPath) {
    char *raw = sp_config_get(keyPath.UTF8String);
    if (!raw) return @"";
    NSString *result = [NSString stringWithUTF8String:raw] ?: @"";
    sp_core_free_string(raw);
    return result;
}

static BOOL configSet(NSString *keyPath, NSString *value) {
    return sp_config_set(keyPath.UTF8String, (value ?: @"").UTF8String) == 0;
}

// Fetch a config sub-tree as a parsed JSON object (NSDictionary / NSArray).
// Returns nil if the key is missing, empty, or not parseable.
static id configGetJSON(NSString *keyPath) {
    char *raw = sp_config_get_json(keyPath.UTF8String);
    if (!raw) return nil;
    NSString *jsonStr = [NSString stringWithUTF8String:raw] ?: @"";
    sp_core_free_string(raw);
    if (jsonStr.length == 0) return nil;
    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return parsed;
}

// Returns user-configured custom headers for the given ASR provider, or nil.
// Mirrors Rust behavior: when `asr.<provider>.headers` is a non-empty map,
// those headers fully replace the provider's default auth headers.
static NSDictionary<NSString *, NSString *> *asrCustomHeaders(NSString *providerKey) {
    NSString *keyPath = [NSString stringWithFormat:@"asr.%@.headers", providerKey];
    id parsed = configGetJSON(keyPath);
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    for (id key in parsed) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id value = parsed[key];
        if (![value isKindOfClass:[NSString class]]) continue;
        out[key] = value;
    }
    return out.count > 0 ? out : nil;
}

static NSInteger clampedOverlayFontSizeValue(NSInteger value) {
    return MAX(kOverlayFontSizeMin, MIN(kOverlayFontSizeMax, value));
}

static NSInteger clampedOverlayBottomMarginValue(NSInteger value) {
    return MAX(0, MIN(kOverlayBottomMarginMax, value));
}

static NSInteger clampedOverlayMaxVisibleLinesValue(NSInteger value) {
    return MAX(kOverlayMaxVisibleLinesMin, MIN(kOverlayMaxVisibleLinesMax, value));
}

static BOOL overlayLimitVisibleLinesEnabledValue(NSString *value) {
    NSString *normalized = [[[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
    if (normalized.length == 0) {
        return kOverlayLimitVisibleLinesDefault;
    }

    if ([normalized isEqualToString:@"1"] ||
        [normalized isEqualToString:@"true"] ||
        [normalized isEqualToString:@"yes"] ||
        [normalized isEqualToString:@"on"]) {
        return YES;
    }

    if ([normalized isEqualToString:@"0"] ||
        [normalized isEqualToString:@"false"] ||
        [normalized isEqualToString:@"no"] ||
        [normalized isEqualToString:@"off"]) {
        return NO;
    }

    return kOverlayLimitVisibleLinesDefault;
}

static NSString *normalizedOverlayFontFamilyValue(NSString *value) {
    NSString *normalized = [[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (normalized.length == 0) {
        return kOverlayFontFamilyDefault;
    }
    return normalized;
}

static BOOL overlayUsesSystemFontFamily(NSString *value) {
    return [normalizedOverlayFontFamilyValue(value) caseInsensitiveCompare:kOverlayFontFamilyDefault] == NSOrderedSame;
}

static NSFont *overlayFontForFamily(NSString *fontFamily, CGFloat fontSize) {
    CGFloat clampedFontSize = clampedOverlayFontSizeValue(lround(fontSize));
    NSString *normalized = normalizedOverlayFontFamilyValue(fontFamily);

    if (overlayUsesSystemFontFamily(normalized)) {
        return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
    }

    NSFont *font = [NSFont fontWithName:normalized size:clampedFontSize];
    if (font) {
        return font;
    }

    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    font = [fontManager fontWithFamily:normalized traits:0 weight:5 size:clampedFontSize];
    if (font) {
        return font;
    }

    for (NSArray *member in [fontManager availableMembersOfFontFamily:normalized]) {
        if (member.count == 0) continue;
        NSString *memberName = member[0];
        font = [NSFont fontWithName:memberName size:clampedFontSize];
        if (font) {
            return font;
        }
    }

    return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
}

static BOOL isNumericKeycode(NSString *value) {
    if (value.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    int intValue;
    return [scanner scanInt:&intValue] && [scanner isAtEnd];
}

static NSString *displayCharacterForKeycode(NSInteger keycode) {
    TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
    if (!inputSource) return nil;

    CFDataRef layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
    if (!layoutData) {
        CFRelease(inputSource);
        return nil;
    }

    const UCKeyboardLayout *keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
    if (!keyboardLayout) {
        CFRelease(inputSource);
        return nil;
    }

    UInt32 deadKeyState = 0;
    UniChar chars[4];
    UniCharCount length = 0;
    OSStatus status = UCKeyTranslate(keyboardLayout,
                                     (UInt16)keycode,
                                     kUCKeyActionDisplay,
                                     0,
                                     LMGetKbdType(),
                                     kUCKeyTranslateNoDeadKeysBit,
                                     &deadKeyState,
                                     sizeof(chars) / sizeof(chars[0]),
                                     &length,
                                     chars);
    CFRelease(inputSource);

    if (status != noErr || length == 0) return nil;

    NSString *result = [[NSString stringWithCharacters:chars length:(NSUInteger)length]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (result.length == 0) return nil;
    return result.uppercaseString;
}

static NSString *displayNameForKeycodeValue(NSString *value) {
    NSInteger keycode = value.integerValue;
    switch (keycode) {
        case 122: return @"F1";
        case 120: return @"F2";
        case 99:  return @"F3";
        case 118: return @"F4";
        case 96:  return @"F5";
        case 97:  return @"F6";
        case 98:  return @"F7";
        case 100: return @"F8";
        case 101: return @"F9";
        case 109: return @"F10";
        case 103: return @"F11";
        case 111: return @"F12";
        case 49:  return @"Space";
        case 53:  return @"Escape";
        case 48:  return @"Tab";
        case 57:  return @"Caps Lock";
        case 36:  return @"Return";
        case 51:  return @"Delete";
        case 117: return @"Forward Delete";
        case 115: return @"Home";
        case 119: return @"End";
        case 116: return @"Page Up";
        case 121: return @"Page Down";
        case 123: return @"Left Arrow";
        case 124: return @"Right Arrow";
        case 125: return @"Down Arrow";
        case 126: return @"Up Arrow";
        default: {
            NSString *displayCharacter = displayCharacterForKeycode(keycode);
            return displayCharacter.length > 0 ? displayCharacter : [NSString stringWithFormat:@"Key %ld", (long)keycode];
        }
    }
}

static NSSet<NSString *> *presetHotkeyValues(void) {
    static NSSet<NSString *> *validValues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        validValues = [NSSet setWithArray:@[
            @"fn",
            @"left_option",
            @"right_option",
            @"left_command",
            @"right_command",
            @"left_control",
            @"right_control",
        ]];
    });
    return validValues;
}

static NSArray<NSString *> *comboModifierOrder(void) {
    return @[@"command", @"option", @"control", @"shift", @"fn"];
}

static NSDictionary<NSString *, NSString *> *comboModifierDisplayNames(void) {
    static NSDictionary<NSString *, NSString *> *displayNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        displayNames = @{
            @"command": @"Command",
            @"option": @"Option",
            @"control": @"Control",
            @"shift": @"Shift",
            @"fn": @"Fn",
        };
    });
    return displayNames;
}

static NSString *normalizedHotkeyComboValue(NSString *value) {
    if (![value containsString:@"+"]) return nil;

    NSMutableOrderedSet<NSString *> *modifiers = [NSMutableOrderedSet orderedSet];
    NSString *keyToken = nil;

    for (NSString *rawPart in [value componentsSeparatedByString:@"+"]) {
        NSString *part = [[rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (part.length == 0) return nil;

        NSString *normalizedModifier = nil;
        if ([part isEqualToString:@"cmd"] || [part isEqualToString:@"command"]) {
            normalizedModifier = @"command";
        } else if ([part isEqualToString:@"alt"] || [part isEqualToString:@"option"]) {
            normalizedModifier = @"option";
        } else if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) {
            normalizedModifier = @"control";
        } else if ([part isEqualToString:@"shift"]) {
            normalizedModifier = @"shift";
        } else if ([part isEqualToString:@"fn"] || [part isEqualToString:@"function"] || [part isEqualToString:@"globe"]) {
            normalizedModifier = @"fn";
        }

        if (normalizedModifier) {
            [modifiers addObject:normalizedModifier];
            continue;
        }

        if (keyToken != nil || !isNumericKeycode(part)) {
            return nil;
        }
        keyToken = [NSString stringWithFormat:@"%ld", (long)part.integerValue];
    }

    if (modifiers.count == 0 || keyToken.length == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *modifier in comboModifierOrder()) {
        if ([modifiers containsObject:modifier]) {
            [parts addObject:modifier];
        }
    }
    [parts addObject:keyToken];
    return [parts componentsJoinedByString:@"+"];
}

static NSString *normalizedHotkeyValue(NSString *value) {
    NSString *trimmedValue = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([presetHotkeyValues() containsObject:trimmedValue]) return trimmedValue;
    if (isNumericKeycode(trimmedValue)) {
        return [NSString stringWithFormat:@"%ld", (long)trimmedValue.integerValue];
    }
    NSString *normalizedCombo = normalizedHotkeyComboValue(trimmedValue);
    if (normalizedCombo.length > 0) return normalizedCombo;
    return @"fn";
}

static NSString *displayNameForHotkeyValue(NSString *value) {
    NSString *normalizedValue = normalizedHotkeyValue(value);
    if ([normalizedValue isEqualToString:@"left_option"]) return @"Left Option (⌥)";
    if ([normalizedValue isEqualToString:@"right_option"]) return @"Right Option (⌥)";
    if ([normalizedValue isEqualToString:@"left_command"]) return @"Left Command (⌘)";
    if ([normalizedValue isEqualToString:@"right_command"]) return @"Right Command (⌘)";
    if ([normalizedValue isEqualToString:@"left_control"]) return @"Left Control (⌃)";
    if ([normalizedValue isEqualToString:@"right_control"]) return @"Right Control (⌃)";
    if ([normalizedValue isEqualToString:@"fn"]) return @"Fn (Globe)";
    NSString *normalizedCombo = normalizedHotkeyComboValue(normalizedValue);
    if (normalizedCombo.length > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSArray<NSString *> *tokens = [normalizedCombo componentsSeparatedByString:@"+"];
        NSDictionary<NSString *, NSString *> *displayNames = comboModifierDisplayNames();
        for (NSInteger idx = 0; idx < (NSInteger)tokens.count; idx++) {
            NSString *token = tokens[idx];
            if (idx == (NSInteger)tokens.count - 1) {
                [parts addObject:displayNameForKeycodeValue(token)];
            } else {
                [parts addObject:displayNames[token] ?: token.capitalizedString];
            }
        }
        return [parts componentsJoinedByString:@" + "];
    }
    if (isNumericKeycode(normalizedValue)) return displayNameForKeycodeValue(normalizedValue);
    return normalizedValue;
}

static BOOL hotkeyValueUsesCustomPopupItem(NSString *value) {
    NSString *normalizedValue = normalizedHotkeyValue(value);
    return isNumericKeycode(normalizedValue) || normalizedHotkeyComboValue(normalizedValue).length > 0;
}

/// If the value is a custom hotkey (recorded combo or raw keycode), add a
/// custom popup item and select it.
static void ensureCustomHotkeyInPopup(NSPopUpButton *popup, NSString *value) {
    NSString *normalizedValue = normalizedHotkeyValue(value);
    if (!hotkeyValueUsesCustomPopupItem(normalizedValue)) return;

    NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
    for (NSMenuItem *item in popup.itemArray) {
        NSString *representedObject = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : nil;
        if (representedObject.length > 0 &&
            ![presetHotkeyValues() containsObject:representedObject] &&
            ![representedObject isEqualToString:normalizedValue]) {
            [itemsToRemove addObject:item];
        }
        if ([representedObject isEqualToString:normalizedValue]) {
            [popup selectItem:item];
            return;
        }
    }

    for (NSMenuItem *item in itemsToRemove) {
        [popup.menu removeItem:item];
    }

    [popup addItemWithTitle:displayNameForHotkeyValue(normalizedValue)];
    [popup lastItem].representedObject = normalizedValue;
    [popup selectItem:[popup lastItem]];
}

// Pane background that follows the system appearance. Using layer.backgroundColor
// with a static CGColor would freeze at the appearance active at creation time;
// overriding updateLayer and resolving inside performAsCurrentDrawingAppearance:
// ensures the colour is re-evaluated on every appearance change.
@interface SPPaneBackgroundView : NSView
@end

@implementation SPPaneBackgroundView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    }];
}
@end

// Elevated card surface (white in light mode, dark-elevated in dark mode) with
// a separator-coloured border. Same dynamic-layer pattern as SPPaneBackgroundView.
@interface SPCardView : NSView
@end

@implementation SPCardView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.cornerRadius = 12.0;
    self.layer.borderWidth = 1.0;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
        self.layer.borderColor = NSColor.separatorColor.CGColor;
    }];
}
@end

@interface SPTemplateRowView : NSTableRowView
@end

@implementation SPTemplateRowView

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.isSelected) return;

    NSRect selectionRect = NSInsetRect(self.bounds, 2.0, 2.0);
    NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:8.0 yRadius:8.0];
    [[NSColor colorWithRed:0.231 green:0.431 blue:0.902 alpha:0.08] setFill];
    [selectionPath fill];
}

- (void)drawSeparatorInRect:(NSRect)dirtyRect {
}

@end

// Row view for the LLM profile list. Draws a prominent accent-colored
// selection background that stays visible even when the table view is not
// the first responder (the detail form on the right steals focus every time
// the user edits a field).
@interface SPLlmProfileRowView : NSTableRowView
@end

@implementation SPLlmProfileRowView

// Keep the cell subviews drawing their "normal" (dark-on-light) appearance
// even when this row is selected — the custom accent background is light
// enough that white text would be unreadable.
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.isSelected) return;

    NSRect selectionRect = NSInsetRect(self.bounds, 3.0, 3.0);
    NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:6.0 yRadius:6.0];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
    [selectionPath fill];

    [[NSColor.controlAccentColor colorWithAlphaComponent:0.85] setStroke];
    selectionPath.lineWidth = 1.5;
    [selectionPath stroke];
}

- (void)drawSeparatorInRect:(NSRect)dirtyRect {
}

@end

// ─── Window Controller ──────────────────────────────────────────────

@interface SPSetupWizardWindowController () <NSToolbarDelegate, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate>

// Current pane
@property (nonatomic, copy) NSString *currentPaneIdentifier;
@property (nonatomic, strong) NSView *currentPaneView;

// ASR fields
@property (nonatomic, strong) NSPopUpButton *asrProviderPopup;
@property (nonatomic, strong) NSTextField *asrAppKeyField;
@property (nonatomic, strong) NSTextField *asrAccessKeyField;
@property (nonatomic, strong) NSSecureTextField *asrAccessKeySecureField;
@property (nonatomic, strong) NSButton *asrAccessKeyToggle;
@property (nonatomic, strong) NSSecureTextField *asrQwenApiKeySecureField;
@property (nonatomic, strong) NSTextField *asrQwenApiKeyField;
@property (nonatomic, strong) NSButton *asrQwenApiKeyToggle;
@property (nonatomic, strong) NSButton *asrTestButton;
@property (nonatomic, strong) NSTextField *asrTestResultLabel;

// Local ASR model selection
@property (nonatomic, strong) NSPopUpButton *localModelPopup;
@property (nonatomic, strong) NSTextField *localModelLabel;
@property (nonatomic, strong) NSTextField *modelStatusLabel;
@property (nonatomic, strong) NSButton *modelDownloadButton;
@property (nonatomic, strong) NSButton *modelDeleteButton;
@property (nonatomic, strong) NSProgressIndicator *modelProgressBar;
@property (nonatomic, strong) NSTextField *modelProgressSizeLabel;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloadingModels;
@property (nonatomic, copy) NSString *pendingVerificationPath;

// Apple Speech locale selection
@property (nonatomic, strong) NSPopUpButton *appleSpeechLocalePopup;

// LLM fields
@property (nonatomic, strong) NSButton *llmEnabledCheckbox;
@property (nonatomic, strong) NSTableView *llmProfileTableView;
@property (nonatomic, strong) NSScrollView *llmProfileTableScroll;
@property (nonatomic, strong) NSButton *llmAddProfileButton;
@property (nonatomic, strong) NSButton *llmDeleteProfileButton;
@property (nonatomic, strong) NSMutableArray<NSString *> *llmProfileOrder;
@property (nonatomic, assign) BOOL suppressLlmProfileSelection;
@property (nonatomic, strong) NSTextField *llmProfileNameField;
@property (nonatomic, strong) NSTextField *llmProfileTypeLabel;
@property (nonatomic, strong) NSTextField *llmBaseUrlField;
@property (nonatomic, strong) NSTextField *llmApiKeyField;
@property (nonatomic, strong) NSSecureTextField *llmApiKeySecureField;
@property (nonatomic, strong) NSButton *llmApiKeyToggle;
@property (nonatomic, strong) NSTextField *llmModelField;
@property (nonatomic, strong) NSButton *llmToggleModelPickerButton;
@property (nonatomic, strong) NSPopUpButton *llmRemoteModelPopup;
@property (nonatomic, strong) NSButton *llmRefreshModelsButton;
@property (nonatomic, strong) NSTextField *llmChatCompletionsPathField;
@property (nonatomic, strong) NSButton *llmTestButton;
@property (nonatomic, strong) NSTextField *llmTestResultLabel;
@property (nonatomic, assign) BOOL llmRemoteModelPickerExpanded;
@property (nonatomic, assign) BOOL llmRemoteModelPickerRowVisible;

// LLM max token parameter
@property (nonatomic, strong) NSPopUpButton *maxTokenParamPopup;

// LLM local model selection (MLX)
@property (nonatomic, strong) NSPopUpButton *llmLocalModelPopup;
@property (nonatomic, strong) NSTextField *llmModelStatusLabel;
@property (nonatomic, strong) NSButton *llmModelDownloadButton;
@property (nonatomic, strong) NSButton *llmModelDeleteButton;
@property (nonatomic, strong) NSProgressIndicator *llmModelProgressBar;
@property (nonatomic, strong) NSTextField *llmModelProgressSizeLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *llmProfiles;
@property (nonatomic, copy) NSString *activeLlmProfileId;

// Hotkey
@property (nonatomic, strong) NSPopUpButton *hotkeyPopup;
@property (nonatomic, strong) NSButton *recordTriggerHotkeyButton;
@property (nonatomic, strong) NSButton *resetTriggerHotkeyButton;
@property (nonatomic, strong) id hotkeyRecordingMonitor;
@property (nonatomic, copy) NSString *recordingHotkeyTarget;
// Trigger mode
@property (nonatomic, strong) NSPopUpButton *triggerModePopup;
@property (nonatomic, strong) NSSwitch *startSoundCheckbox;
@property (nonatomic, strong) NSSwitch *stopSoundCheckbox;
@property (nonatomic, strong) NSSwitch *errorSoundCheckbox;

// Overlay
@property (nonatomic, strong) NSPopUpButton *overlayFontFamilyPopup;
@property (nonatomic, copy) NSArray<NSString *> *overlayAvailableFontFamilies;
@property (nonatomic, strong) NSSlider *overlayFontSizeSlider;
@property (nonatomic, strong) NSTextField *overlayFontSizeValueLabel;
@property (nonatomic, strong) NSSlider *overlayBottomMarginSlider;
@property (nonatomic, strong) NSTextField *overlayBottomMarginValueLabel;
@property (nonatomic, strong) NSSwitch *overlayLimitVisibleLinesSwitch;
@property (nonatomic, strong) NSPopUpButton *overlayMaxVisibleLinesPopup;

// Dictionary
@property (nonatomic, strong) NSTextView *dictionaryTextView;

// System Prompt
@property (nonatomic, strong) NSTextView *systemPromptTextView;

// Templates
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *templatesData;
@property (nonatomic, strong) NSTableView *templatesTableView;
@property (nonatomic, strong) NSSwitch *templatesEnabledSwitch;
@property (nonatomic, strong) NSSegmentedControl *templatePrimaryActionsControl;
@property (nonatomic, strong) NSSegmentedControl *templateReorderActionsControl;
@property (nonatomic, strong) NSTextField *templateNameField;
@property (nonatomic, strong) NSSwitch *templateItemEnabledSwitch;
@property (nonatomic, strong) NSTextView *templatePromptTextView;
@property (nonatomic, assign) NSInteger selectedTemplateIndex;
@property (nonatomic, assign) BOOL suppressTemplateSync;
@property (nonatomic, assign) BOOL templateEditorDirty;

@end

@implementation SPSetupWizardWindowController {
    dispatch_queue_t _verifyQueue;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 600, 400)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    window.title = @"Koe Settings";
    window.toolbarStyle = NSWindowToolbarStylePreference;

    self = [super initWithWindow:window];
    if (self) {
        _verifyQueue = dispatch_queue_create("koe.model.verify", DISPATCH_QUEUE_SERIAL);
        window.delegate = self;
        [self setupToolbar];
    }
    return self;
}

- (void)showWindow:(id)sender {
    if (!self.currentPaneIdentifier) {
        [self switchToPane:kToolbarASR];
    }
    [self loadCurrentValues];
    [self.window center];
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self endHotkeyRecording];
    [self hideRuntimeOverlayPreview];
}

// ─── Toolbar ────────────────────────────────────────────────────────

- (void)setupToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"KoeSettingsToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    toolbar.selectedItemIdentifier = kToolbarASR;
    self.window.toolbar = toolbar;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarOverlay, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt, kToolbarTemplates, kToolbarAbout];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarOverlay, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt, kToolbarTemplates, kToolbarAbout];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarOverlay, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt, kToolbarTemplates, kToolbarAbout];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.target = self;
    item.action = @selector(toolbarItemClicked:);

    if ([itemIdentifier isEqualToString:kToolbarASR]) {
        item.label = @"ASR";
        item.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"ASR"];
    } else if ([itemIdentifier isEqualToString:kToolbarLLM]) {
        item.label = @"LLM";
        item.image = [NSImage imageWithSystemSymbolName:@"cpu" accessibilityDescription:@"LLM"];
    } else if ([itemIdentifier isEqualToString:kToolbarOverlay]) {
        item.label = @"Overlay";
        item.image = [NSImage imageWithSystemSymbolName:@"captions.bubble" accessibilityDescription:@"Overlay"];
    } else if ([itemIdentifier isEqualToString:kToolbarHotkey]) {
        item.label = @"Controls";
        item.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Controls"];
    } else if ([itemIdentifier isEqualToString:kToolbarDictionary]) {
        item.label = @"Dictionary";
        item.image = [NSImage imageWithSystemSymbolName:@"book" accessibilityDescription:@"Dictionary"];
    } else if ([itemIdentifier isEqualToString:kToolbarSystemPrompt]) {
        item.label = @"Prompt";
        item.image = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:@"System Prompt"];
    } else if ([itemIdentifier isEqualToString:kToolbarTemplates]) {
        item.label = @"Templates";
        item.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Templates"];
    } else if ([itemIdentifier isEqualToString:kToolbarAbout]) {
        item.label = @"About";
        item.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:@"About"];
    }

    return item;
}

- (void)toolbarItemClicked:(NSToolbarItem *)sender {
    [self switchToPane:sender.itemIdentifier];
}

// ─── Pane Switching ─────────────────────────────────────────────────

- (void)switchToPane:(NSString *)identifier {
    if ([self.currentPaneIdentifier isEqualToString:identifier]) return;

    // Save template edits before switching away
    if ([self.currentPaneIdentifier isEqualToString:kToolbarTemplates]) {
        [self saveCurrentTemplateEdits];
    } else if ([self.currentPaneIdentifier isEqualToString:kToolbarOverlay]) {
        [self hideRuntimeOverlayPreview];
    }
    [self endHotkeyRecording];

    self.currentPaneIdentifier = identifier;

    // Remove old pane
    [self.currentPaneView removeFromSuperview];

    // Build new pane
    NSView *paneView;
    if ([identifier isEqualToString:kToolbarASR]) {
        paneView = [self buildAsrPane];
    } else if ([identifier isEqualToString:kToolbarLLM]) {
        paneView = [self buildLlmPane];
    } else if ([identifier isEqualToString:kToolbarOverlay]) {
        paneView = [self buildOverlayPane];
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        paneView = [self buildHotkeyPane];
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        paneView = [self buildDictionaryPane];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        paneView = [self buildSystemPromptPane];
    } else if ([identifier isEqualToString:kToolbarTemplates]) {
        paneView = [self buildTemplatesPane];
    } else if ([identifier isEqualToString:kToolbarAbout]) {
        paneView = [self buildAboutPane];
    }

    if (!paneView) return;

    self.currentPaneView = paneView;
    self.window.toolbar.selectedItemIdentifier = identifier;

    // Resize window to fit pane with animation
    NSSize paneSize = paneView.frame.size;
    NSRect windowFrame = self.window.frame;
    CGFloat contentHeight = paneSize.height;
    CGFloat titleBarHeight = windowFrame.size.height - [self.window.contentView frame].size.height;
    CGFloat newHeight = contentHeight + titleBarHeight;
    CGFloat newWidth = paneSize.width;

    NSRect newFrame = NSMakeRect(
        windowFrame.origin.x + (windowFrame.size.width - newWidth) / 2.0,
        windowFrame.origin.y + windowFrame.size.height - newHeight,
        newWidth,
        newHeight
    );

    [self.window setFrame:newFrame display:YES animate:YES];

    // Add pane to window
    paneView.frame = [self.window.contentView bounds];
    paneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:paneView];

    // Reload values for this pane
    [self loadValuesForPane:identifier];
}

// ─── Build Panes ────────────────────────────────────────────────────

- (NSView *)buildAsrPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat fieldW = paneWidth - fieldX - 32;
    CGFloat rowH = 32;
    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;

    // Calculate content height
    CGFloat contentHeight = 260;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat y = contentHeight - 30.0;

    // Description
    NSTextField *desc = [self addSettingsDescriptionText:@"Choose the ASR provider used for transcription."
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];

    NSTextField *sectionTitle = [self sectionTitleLabel:@"Connection"
                                                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0), contentW, 20)];
    [pane addSubview:sectionTitle];
    y = NSMinY(sectionTitle.frame) - 32.0;
    CGFloat formStartY = y;

    // Provider
    [pane addSubview:[self formLabel:@"Provider" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 200, 26) pullsDown:NO];
    [self.asrProviderPopup addItemWithTitle:@"DoubaoIME (Built-in, Free)"];
    [self.asrProviderPopup lastItem].representedObject = @"doubaoime";
    [self.asrProviderPopup addItemWithTitle:@"Doubao (ByteDance)"];
    [self.asrProviderPopup lastItem].representedObject = @"doubao";
    [self.asrProviderPopup addItemWithTitle:@"Qwen (Alibaba Cloud)"];
    [self.asrProviderPopup lastItem].representedObject = @"qwen";
    NSArray<NSString *> *supportedLocalProviders = [self.rustBridge supportedLocalProviders];
    // Add Apple Speech (macOS 26+, no model download required; also requires the
    // apple-speech feature to be compiled into the Rust core — excluded on x86_64)
    if (@available(macOS 26.0, *)) {
        if ([supportedLocalProviders containsObject:@"apple-speech"]) {
            [self.asrProviderPopup addItemWithTitle:@"Apple Speech (On-Device)"];
            [self.asrProviderPopup lastItem].representedObject = @"apple-speech";
        }
    }
    // Add local providers supported by this build (model-based)
    NSDictionary *localProviderLabels = @{
        @"mlx": @"MLX (Apple Silicon)",
        @"sherpa-onnx": @"Sherpa-ONNX",
    };
    for (NSString *provider in supportedLocalProviders) {
        NSString *label = localProviderLabels[provider];
        if (!label) continue;  // apple-speech handled above
        [self.asrProviderPopup addItemWithTitle:label];
        [self.asrProviderPopup lastItem].representedObject = provider;
    }
    [self.asrProviderPopup setTarget:self];
    [self.asrProviderPopup setAction:@selector(asrProviderChanged:)];
    [pane addSubview:self.asrProviderPopup];

    // Test button next to Provider
    self.asrTestButton = [NSButton buttonWithTitle:@"Test" target:self action:@selector(testAsrConnection:)];
    self.asrTestButton.bezelStyle = NSBezelStyleRounded;
    self.asrTestButton.frame = NSMakeRect(fieldX + 208, y - 2, 70, 28);
    [pane addSubview:self.asrTestButton];
    y -= rowH;

    // App Key (Doubao only)
    self.asrAppKeyField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"Volcengine App ID"];
    [pane addSubview:self.asrAppKeyField];
    NSTextField *appKeyLabel = [self formLabel:@"App Key" frame:NSMakeRect(16, y, labelW, 22)];
    appKeyLabel.tag = 1001;
    [pane addSubview:appKeyLabel];

    // Apple Speech locale popup (same row as App Key / Model, tag 1005)
    NSTextField *localeLabel = [self formLabel:@"Language" frame:NSMakeRect(16, y, labelW, 22)];
    localeLabel.tag = 1005;
    localeLabel.hidden = YES;
    [pane addSubview:localeLabel];
    self.appleSpeechLocalePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, fieldW - 26, 26) pullsDown:NO];
    self.appleSpeechLocalePopup.hidden = YES;
    [self.appleSpeechLocalePopup setTarget:self];
    [self.appleSpeechLocalePopup setAction:@selector(appleSpeechLocaleChanged:)];
    // Populate from system-reported supported locales
    [self populateAppleSpeechLocalePopup];
    [pane addSubview:self.appleSpeechLocalePopup];

    // Row 1: Model popup + Download button (Local providers, same row as App Key)
    self.localModelLabel = [self formLabel:@"Model" frame:NSMakeRect(16, y, labelW, 22)];
    self.localModelLabel.tag = 1004;
    self.localModelLabel.hidden = YES;
    [pane addSubview:self.localModelLabel];
    self.localModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, fieldW - 26, 26) pullsDown:NO];
    self.localModelPopup.hidden = YES;
    [self.localModelPopup setTarget:self];
    [self.localModelPopup setAction:@selector(localModelChanged:)];
    [pane addSubview:self.localModelPopup];

    // Download button (right of model popup, same style as eye button)
    self.modelDownloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                  accessibilityDescription:@"Download"];
    self.modelDownloadButton.bezelStyle = NSBezelStyleInline;
    self.modelDownloadButton.bordered = NO;
    self.modelDownloadButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.modelDownloadButton.target = self;
    self.modelDownloadButton.action = @selector(downloadSelectedModel:);
    self.modelDownloadButton.hidden = YES;
    [pane addSubview:self.modelDownloadButton];

    y -= rowH;

    // Row 2: Status + Delete button
    self.modelStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y + 2, fieldW - 32, 18)];
    self.modelStatusLabel.bezeled = NO;
    self.modelStatusLabel.drawsBackground = NO;
    self.modelStatusLabel.editable = NO;
    self.modelStatusLabel.selectable = NO;
    self.modelStatusLabel.font = [NSFont systemFontOfSize:12];
    self.modelStatusLabel.hidden = YES;
    [pane addSubview:self.modelStatusLabel];

    // Delete button (right end of status row, same style as eye button)
    self.modelDeleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
    self.modelDeleteButton.image = [NSImage imageWithSystemSymbolName:@"trash"
                                                accessibilityDescription:@"Delete"];
    self.modelDeleteButton.bezelStyle = NSBezelStyleInline;
    self.modelDeleteButton.bordered = NO;
    self.modelDeleteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.modelDeleteButton.target = self;
    self.modelDeleteButton.action = @selector(deleteSelectedModel:);
    self.modelDeleteButton.hidden = YES;
    [pane addSubview:self.modelDeleteButton];

    y -= rowH;

    // Row 3: Progress bar + size label
    self.modelProgressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(fieldX, y + 10, fieldW - 120, 10)];
    self.modelProgressBar.controlSize = NSControlSizeMini;
    self.modelProgressBar.style = NSProgressIndicatorStyleBar;
    self.modelProgressBar.minValue = 0;
    self.modelProgressBar.maxValue = 100;
    self.modelProgressBar.indeterminate = NO;
    self.modelProgressBar.hidden = YES;
    [pane addSubview:self.modelProgressBar];

    self.modelProgressSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 114, y + 2, 114, 18)];
    self.modelProgressSizeLabel.bezeled = NO;
    self.modelProgressSizeLabel.drawsBackground = NO;
    self.modelProgressSizeLabel.editable = NO;
    self.modelProgressSizeLabel.selectable = NO;
    self.modelProgressSizeLabel.alignment = NSTextAlignmentRight;
    self.modelProgressSizeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.modelProgressSizeLabel.textColor = [NSColor secondaryLabelColor];
    self.modelProgressSizeLabel.hidden = YES;
    [pane addSubview:self.modelProgressSizeLabel];

    y -= rowH;

    // Access Key (Doubao) — fixed at row 2 (same as Qwen API Key)
    CGFloat accessKeyY = formStartY - rowH - rowH;
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;

    self.asrAccessKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, accessKeyY, secFieldW, 22)];
    self.asrAccessKeySecureField.placeholderString = @"Volcengine Access Token";
    self.asrAccessKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrAccessKeySecureField];
    self.asrAccessKeyField = [self formTextField:NSMakeRect(fieldX, accessKeyY, secFieldW, 22) placeholder:@"Volcengine Access Token"];
    self.asrAccessKeyField.hidden = YES;
    [pane addSubview:self.asrAccessKeyField];
    self.asrAccessKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, accessKeyY - 1, eyeW, 24)
                                                action:@selector(toggleAsrAccessKeyVisibility:)];
    [pane addSubview:self.asrAccessKeyToggle];
    NSTextField *accessKeyLabel = [self formLabel:@"Access Key" frame:NSMakeRect(16, accessKeyY, labelW, 22)];
    accessKeyLabel.tag = 1002;
    [pane addSubview:accessKeyLabel];

    // Qwen API Key — fixed at row 1 (same position as App Key)
    CGFloat qwenY = formStartY - rowH;
    self.asrQwenApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, qwenY, secFieldW, 22)];
    self.asrQwenApiKeySecureField.placeholderString = @"DashScope API Key (sk-xxx)";
    self.asrQwenApiKeySecureField.font = [NSFont systemFontOfSize:13];
    self.asrQwenApiKeySecureField.hidden = YES;
    [pane addSubview:self.asrQwenApiKeySecureField];
    self.asrQwenApiKeyField = [self formTextField:NSMakeRect(fieldX, qwenY, secFieldW, 22) placeholder:@"DashScope API Key (sk-xxx)"];
    self.asrQwenApiKeyField.hidden = YES;
    [pane addSubview:self.asrQwenApiKeyField];
    self.asrQwenApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, qwenY - 1, eyeW, 24)
                                                action:@selector(toggleQwenApiKeyVisibility:)];
    self.asrQwenApiKeyToggle.hidden = YES;
    [pane addSubview:self.asrQwenApiKeyToggle];
    NSTextField *qwenKeyLabel = [self formLabel:@"API Key" frame:NSMakeRect(16, qwenY, labelW, 22)];
    qwenKeyLabel.tag = 1003;
    qwenKeyLabel.hidden = YES;
    [pane addSubview:qwenKeyLabel];

    // Test result label — positioned below credential fields with enough
    // width/height for multi-line error messages.
    self.asrTestResultLabel = [NSTextField wrappingLabelWithString:@""];
    CGFloat testResultY = accessKeyY - 48;
    self.asrTestResultLabel.frame = NSMakeRect(fieldX,
                                               testResultY,
                                               paneWidth - fieldX - 24,
                                               42);
    self.asrTestResultLabel.font = [NSFont systemFontOfSize:12];
    self.asrTestResultLabel.selectable = YES;
    [pane addSubview:self.asrTestResultLabel];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildLlmPane {
    CGFloat paneWidth = 600;
    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;
    CGFloat contentHeight = 580;

    // Sidebar (profile list) geometry
    CGFloat sidebarX = 24.0;
    CGFloat sidebarW = 160.0;
    CGFloat sidebarButtonsH = 28.0;

    // Detail form geometry (right of sidebar)
    CGFloat labelW = 96;
    CGFloat detailLabelX = sidebarX + sidebarW + 16;
    CGFloat fieldX = detailLabelX + labelW + 8;
    CGFloat fieldW = paneWidth - fieldX - 24;
    CGFloat rowH = 32;

    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat y = contentHeight - 30.0;

    // Description
    NSTextField *desc = [self addSettingsDescriptionText:@"Configure LLM for post-correction. When disabled, raw ASR output is used directly."
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];
    y = NSMinY(desc.frame) - 16.0;

    // Enabled toggle
    self.llmEnabledCheckbox = [self settingsSwitchWithAction:@selector(llmEnabledToggled:)];
    NSView *llmEnabledCard = [self settingsToggleCardWithFrame:NSMakeRect(contentX, y - 48.0, contentW, 48.0)
                                                         title:@"LLM Correction"
                                                        toggle:self.llmEnabledCheckbox];
    [pane addSubview:llmEnabledCard];
    y = NSMinY(llmEnabledCard.frame) - 24.0;

    NSTextField *sectionTitle = [self sectionTitleLabel:@"Profiles"
                                                  frame:NSMakeRect(contentX, floor(y - 20.0), contentW, 20.0)];
    [pane addSubview:sectionTitle];
    y = NSMinY(sectionTitle.frame) - 16.0;

    // Bottom of the profiles area — leave room for save/cancel buttons (60pt)
    CGFloat profilesBottomY = 64.0;
    CGFloat sidebarH = y - profilesBottomY;
    CGFloat sidebarY = profilesBottomY;

    // ─── Sidebar: profile list ─────────────────────────────────────────
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(sidebarX, sidebarY + sidebarButtonsH, sidebarW, sidebarH - sidebarButtonsH)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.borderType = NSBezelBorder;
    scroll.autohidesScrollers = YES;
    self.llmProfileTableScroll = scroll;

    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    table.headerView = nil;
    table.rowHeight = 44;
    table.allowsEmptySelection = NO;
    table.allowsMultipleSelection = NO;
    table.intercellSpacing = NSMakeSize(0, 0);
    table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    table.dataSource = self;
    table.delegate = self;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"LlmProfileColumn"];
    col.width = sidebarW - 4;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:col];

    scroll.documentView = table;
    [pane addSubview:scroll];
    self.llmProfileTableView = table;

    // Sidebar +/- buttons (Finder-style)
    self.llmAddProfileButton = [[NSButton alloc] initWithFrame:NSMakeRect(sidebarX, sidebarY, 28, 24)];
    self.llmAddProfileButton.bezelStyle = NSBezelStyleSmallSquare;
    self.llmAddProfileButton.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add"];
    self.llmAddProfileButton.target = self;
    self.llmAddProfileButton.action = @selector(showAddLlmProfileMenu:);
    [pane addSubview:self.llmAddProfileButton];

    self.llmDeleteProfileButton = [[NSButton alloc] initWithFrame:NSMakeRect(sidebarX + 30, sidebarY, 28, 24)];
    self.llmDeleteProfileButton.bezelStyle = NSBezelStyleSmallSquare;
    self.llmDeleteProfileButton.image = [NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"Delete"];
    self.llmDeleteProfileButton.target = self;
    self.llmDeleteProfileButton.action = @selector(deleteLlmProfile:);
    [pane addSubview:self.llmDeleteProfileButton];

    // ─── Detail form (right side) ─────────────────────────────────────
    CGFloat detailY = y;  // top of form area aligns with top of sidebar

    // Name field (editable custom display name for this profile)
    NSTextField *nameLabel = [self formLabel:@"Name" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    [pane addSubview:nameLabel];
    self.llmProfileNameField = [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22) placeholder:@"My profile"];
    self.llmProfileNameField.target = self;
    self.llmProfileNameField.action = @selector(llmProfileNameChanged:);
    self.llmProfileNameField.delegate = self;
    [pane addSubview:self.llmProfileNameField];
    detailY -= rowH;

    // Type (read-only label — locked at creation)
    NSTextField *typeLabelLeft = [self formLabel:@"Type" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    [pane addSubview:typeLabelLeft];
    self.llmProfileTypeLabel = [NSTextField labelWithString:@""];
    self.llmProfileTypeLabel.frame = NSMakeRect(fieldX, detailY, fieldW, 22);
    self.llmProfileTypeLabel.font = [NSFont systemFontOfSize:13];
    self.llmProfileTypeLabel.textColor = [NSColor secondaryLabelColor];
    [pane addSubview:self.llmProfileTypeLabel];
    detailY -= rowH + 4;

    CGFloat providerDetailStartY = detailY;

    // --- OpenAI fields (tag 2001-2008 for show/hide) ---

    // Base URL
    NSTextField *baseUrlLabel = [self formLabel:@"Base URL" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    baseUrlLabel.tag = 2001;
    [pane addSubview:baseUrlLabel];
    self.llmBaseUrlField = [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22) placeholder:@"https://api.openai.com/v1"];
    self.llmBaseUrlField.tag = 2001;
    [pane addSubview:self.llmBaseUrlField];
    detailY -= rowH;

    // API Key (secure by default)
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;
    NSTextField *apiKeyLabel = [self formLabel:@"API Key" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    apiKeyLabel.tag = 2002;
    [pane addSubview:apiKeyLabel];
    self.llmApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, detailY, secFieldW, 22)];
    self.llmApiKeySecureField.placeholderString = @"sk-... (leave empty if not required)";
    self.llmApiKeySecureField.font = [NSFont systemFontOfSize:13];
    self.llmApiKeySecureField.tag = 2002;
    [pane addSubview:self.llmApiKeySecureField];
    self.llmApiKeyField = [self formTextField:NSMakeRect(fieldX, detailY, secFieldW, 22) placeholder:@"sk-... (leave empty if not required)"];
    self.llmApiKeyField.hidden = YES;
    self.llmApiKeyField.tag = 2002;
    [pane addSubview:self.llmApiKeyField];
    self.llmApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, detailY - 1, eyeW, 24)
                                             action:@selector(toggleLlmApiKeyVisibility:)];
    [pane addSubview:self.llmApiKeyToggle];
    detailY -= rowH;

    // Model (text field for OpenAI) + Choose button (toggles remote model picker)
    CGFloat modelPickerButtonW = 74;
    CGFloat modelFieldW = fieldW - modelPickerButtonW - 6;
    NSTextField *modelLabel = [self formLabel:@"Model" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    modelLabel.tag = 2003;
    [pane addSubview:modelLabel];
    self.llmModelField = [self formTextField:NSMakeRect(fieldX, detailY, modelFieldW, 22) placeholder:@"gpt-5.4-nano"];
    self.llmModelField.tag = 2003;
    [pane addSubview:self.llmModelField];
    self.llmToggleModelPickerButton = [NSButton buttonWithTitle:@"Choose"
                                                          target:self
                                                          action:@selector(toggleLlmRemoteModelPicker:)];
    self.llmToggleModelPickerButton.frame = NSMakeRect(fieldX + modelFieldW + 6, detailY - 2, modelPickerButtonW, 26);
    self.llmToggleModelPickerButton.bezelStyle = NSBezelStyleRounded;
    self.llmToggleModelPickerButton.tag = 2003;
    [pane addSubview:self.llmToggleModelPickerButton];
    detailY -= rowH;

    // Model List (OpenAI /models) — initially hidden, toggled by Choose button
    NSTextField *modelListLabel = [self formLabel:@"Model List" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    modelListLabel.tag = 2004;
    [pane addSubview:modelListLabel];
    self.llmRemoteModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, detailY - 2, fieldW - 74, 26) pullsDown:NO];
    self.llmRemoteModelPopup.tag = 2004;
    [self.llmRemoteModelPopup addItemWithTitle:@"No models loaded"];
    self.llmRemoteModelPopup.enabled = NO;
    [self.llmRemoteModelPopup setTarget:self];
    [self.llmRemoteModelPopup setAction:@selector(llmRemoteModelChanged:)];
    [pane addSubview:self.llmRemoteModelPopup];
    self.llmRefreshModelsButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshLlmRemoteModels:)];
    self.llmRefreshModelsButton.frame = NSMakeRect(fieldX + fieldW - 66, detailY - 2, 66, 26);
    self.llmRefreshModelsButton.bezelStyle = NSBezelStyleRounded;
    self.llmRefreshModelsButton.tag = 2004;
    [pane addSubview:self.llmRefreshModelsButton];
    self.llmRemoteModelPickerExpanded = NO;
    self.llmRemoteModelPickerRowVisible = YES;
    [self setHidden:YES forViewsWithTagInRange:NSMakeRange(2004, 1) inView:pane];
    detailY -= rowH + 4;

    // Chat Completions Path
    NSTextField *chatPathLabel = [self formLabel:@"Chat Path" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    chatPathLabel.tag = 2005;
    [pane addSubview:chatPathLabel];
    self.llmChatCompletionsPathField = [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22)
                                                placeholder:kDefaultLlmChatCompletionsPath];
    self.llmChatCompletionsPathField.tag = 2005;
    [pane addSubview:self.llmChatCompletionsPathField];
    detailY -= rowH;

    // Max Token Parameter
    NSTextField *tokenParamLabel = [self formLabel:@"Token Parameter" frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
    tokenParamLabel.tag = 2006;
    [pane addSubview:tokenParamLabel];
    self.maxTokenParamPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, detailY - 2, 240, 26) pullsDown:NO];
    self.maxTokenParamPopup.tag = 2006;
    [self.maxTokenParamPopup addItemsWithTitles:@[
        @"max_completion_tokens",
        @"max_tokens",
    ]];
    [self.maxTokenParamPopup itemAtIndex:0].representedObject = @"max_completion_tokens";
    [self.maxTokenParamPopup itemAtIndex:1].representedObject = @"max_tokens";
    [pane addSubview:self.maxTokenParamPopup];
    detailY -= 42;

    // Hint text
    NSTextField *tokenHint = [self descriptionLabel:@"GPT-4o and older models use max_tokens. GPT-5 and reasoning models (o1/o3) use max_completion_tokens."];
    tokenHint.frame = NSMakeRect(fieldX, detailY - 2, fieldW, 32);
    tokenHint.tag = 2007;
    [pane addSubview:tokenHint];
    detailY -= 44;

    // Test button
    self.llmTestButton = [NSButton buttonWithTitle:@"Test Connection" target:self action:@selector(testLlmConnection:)];
    self.llmTestButton.bezelStyle = NSBezelStyleRounded;
    self.llmTestButton.frame = NSMakeRect(fieldX, detailY, 130, 28);
    self.llmTestButton.tag = 2008;
    [pane addSubview:self.llmTestButton];
    detailY -= 32;

    // Test result
    self.llmTestResultLabel = [NSTextField wrappingLabelWithString:@""];
    self.llmTestResultLabel.frame = NSMakeRect(fieldX, detailY - 36, fieldW, 42);
    self.llmTestResultLabel.font = [NSFont systemFontOfSize:12];
    self.llmTestResultLabel.selectable = YES;
    self.llmTestResultLabel.tag = 2008;
    [pane addSubview:self.llmTestResultLabel];

    // --- MLX fields (tag 2010-2012 for show/hide, initially hidden) ---
    CGFloat mlxY = providerDetailStartY;  // same Y as Base URL row

    // MLX Model popup + Download button
    NSTextField *llmModelLabel = [self formLabel:@"Model" frame:NSMakeRect(detailLabelX, mlxY, labelW, 22)];
    llmModelLabel.tag = 2010;
    llmModelLabel.hidden = YES;
    [pane addSubview:llmModelLabel];
    self.llmLocalModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, mlxY - 2, fieldW - 26, 26) pullsDown:NO];
    self.llmLocalModelPopup.tag = 2010;
    self.llmLocalModelPopup.hidden = YES;
    [self.llmLocalModelPopup setTarget:self];
    [self.llmLocalModelPopup setAction:@selector(llmLocalModelChanged:)];
    [pane addSubview:self.llmLocalModelPopup];

    self.llmModelDownloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, mlxY + 1, 20, 20)];
    self.llmModelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                      accessibilityDescription:@"Download"];
    self.llmModelDownloadButton.bezelStyle = NSBezelStyleInline;
    self.llmModelDownloadButton.bordered = NO;
    self.llmModelDownloadButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.llmModelDownloadButton.target = self;
    self.llmModelDownloadButton.action = @selector(llmDownloadSelectedModel:);
    self.llmModelDownloadButton.tag = 2010;
    self.llmModelDownloadButton.hidden = YES;
    [pane addSubview:self.llmModelDownloadButton];

    mlxY -= rowH;

    // MLX Status + Delete button
    self.llmModelStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, mlxY + 2, fieldW - 32, 18)];
    self.llmModelStatusLabel.bezeled = NO;
    self.llmModelStatusLabel.drawsBackground = NO;
    self.llmModelStatusLabel.editable = NO;
    self.llmModelStatusLabel.selectable = NO;
    self.llmModelStatusLabel.font = [NSFont systemFontOfSize:12];
    self.llmModelStatusLabel.tag = 2011;
    self.llmModelStatusLabel.hidden = YES;
    [pane addSubview:self.llmModelStatusLabel];

    self.llmModelDeleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, mlxY + 1, 20, 20)];
    self.llmModelDeleteButton.image = [NSImage imageWithSystemSymbolName:@"trash"
                                                    accessibilityDescription:@"Delete"];
    self.llmModelDeleteButton.bezelStyle = NSBezelStyleInline;
    self.llmModelDeleteButton.bordered = NO;
    self.llmModelDeleteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.llmModelDeleteButton.target = self;
    self.llmModelDeleteButton.action = @selector(llmDeleteSelectedModel:);
    self.llmModelDeleteButton.tag = 2011;
    self.llmModelDeleteButton.hidden = YES;
    [pane addSubview:self.llmModelDeleteButton];

    mlxY -= rowH;

    // MLX Progress bar + size label
    self.llmModelProgressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(fieldX, mlxY + 10, fieldW - 120, 10)];
    self.llmModelProgressBar.controlSize = NSControlSizeMini;
    self.llmModelProgressBar.style = NSProgressIndicatorStyleBar;
    self.llmModelProgressBar.minValue = 0;
    self.llmModelProgressBar.maxValue = 100;
    self.llmModelProgressBar.indeterminate = NO;
    self.llmModelProgressBar.hidden = YES;
    [pane addSubview:self.llmModelProgressBar];

    self.llmModelProgressSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 114, mlxY + 2, 114, 18)];
    self.llmModelProgressSizeLabel.bezeled = NO;
    self.llmModelProgressSizeLabel.drawsBackground = NO;
    self.llmModelProgressSizeLabel.editable = NO;
    self.llmModelProgressSizeLabel.selectable = NO;
    self.llmModelProgressSizeLabel.alignment = NSTextAlignmentRight;
    self.llmModelProgressSizeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.llmModelProgressSizeLabel.textColor = [NSColor secondaryLabelColor];
    self.llmModelProgressSizeLabel.hidden = YES;
    [pane addSubview:self.llmModelProgressSizeLabel];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildOverlayPane {
    CGFloat paneWidth = 600.0;
    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;
    NSString *descriptionText = @"Adjust the bottom live transcript overlay. Choose a system font, tune text size, set the bottom distance, and decide whether long live text stays capped to a few lines or expands fully. Every change is previewed directly in the real desktop overlay position.";

    self.overlayFontFamilyPopup = [self overlayFontFamilyPopupControl];

    self.overlayFontSizeSlider = [self overlaySliderWithMin:kOverlayFontSizeMin
                                                        max:kOverlayFontSizeMax
                                                     action:@selector(overlayControlChanged:)];
    self.overlayFontSizeValueLabel = [self overlayValueLabel];
    NSView *fontSliderControl = [self sliderControlWithSlider:self.overlayFontSizeSlider
                                                   valueLabel:self.overlayFontSizeValueLabel
                                                        width:290.0];

    self.overlayBottomMarginSlider = [self overlaySliderWithMin:0
                                                            max:kOverlayBottomMarginMax
                                                         action:@selector(overlayControlChanged:)];
    self.overlayBottomMarginValueLabel = [self overlayValueLabel];
    NSView *bottomSliderControl = [self sliderControlWithSlider:self.overlayBottomMarginSlider
                                                     valueLabel:self.overlayBottomMarginValueLabel
                                                          width:290.0];

    self.overlayLimitVisibleLinesSwitch = [self settingsSwitchWithAction:@selector(overlayControlChanged:)];
    self.overlayMaxVisibleLinesPopup = [self overlayMaxVisibleLinesPopupControl];

    NSButton *resetButton = [NSButton buttonWithTitle:@"Reset to Default"
                                               target:self
                                               action:@selector(resetOverlaySettings:)];
    resetButton.bezelStyle = NSBezelStyleRounded;
    resetButton.frame = NSMakeRect(0, 0, 126.0, 28.0);

    NSView *controlsCard = [self cardWithTitle:@"Overlay"
                                          rows:@[
        [self cardRowWithLabel:@"Font" control:self.overlayFontFamilyPopup],
        [self cardRowWithLabel:@"Text Size" control:fontSliderControl],
        [self cardRowWithLabel:@"Distance from Bottom" control:bottomSliderControl],
        [self cardRowWithLabel:@"Limit Visible Lines" control:self.overlayLimitVisibleLinesSwitch],
        [self cardRowWithLabel:@"Max Visible Lines" control:self.overlayMaxVisibleLinesPopup],
        [self cardRowWithLabel:@"Defaults" control:resetButton],
    ]
                                         width:contentW];
    CGFloat descriptionHeight = [self fittingHeightForWrappingLabel:[self descriptionLabel:descriptionText] width:contentW];
    CGFloat paneHeight = 30.0 + descriptionHeight + 18.0 + 20.0 + 12.0 + controlsCard.frame.size.height + 60.0;

    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, paneHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat y = paneHeight - 30.0;
    NSTextField *desc = [self addSettingsDescriptionText:descriptionText
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];
    y = NSMinY(desc.frame) - 18.0;

    CGFloat controlsTitleY = y - 20.0;
    NSTextField *controlsTitle = [self sectionTitleLabel:@"Style Controls"
                                                   frame:NSMakeRect(contentX, controlsTitleY, contentW, 20.0)];
    [pane addSubview:controlsTitle];
    controlsCard.frame = NSMakeRect(contentX,
                                    NSMinY(controlsTitle.frame) - 12.0 - controlsCard.frame.size.height,
                                    contentW,
                                    controlsCard.frame.size.height);
    [pane addSubview:controlsCard];
    NSView *controlsCardBody = controlsCard.subviews.count > 1 ? controlsCard.subviews[1] : controlsCard.subviews[0];
    [self layoutCardRowControls:controlsCardBody width:contentW];
    [self updateOverlayLineLimitControlsEnabled];

    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (void)updateOverlayControlValueLabels {
    self.overlayFontSizeValueLabel.stringValue = [NSString stringWithFormat:@"%ld pt", (long)clampedOverlayFontSizeValue(lround(self.overlayFontSizeSlider.doubleValue))];
    self.overlayBottomMarginValueLabel.stringValue = [NSString stringWithFormat:@"%ld pt", (long)clampedOverlayBottomMarginValue(lround(self.overlayBottomMarginSlider.doubleValue))];
}

- (SPOverlayPanel *)runtimeOverlayPanel {
    id appDelegate = NSApp.delegate;
    if (!appDelegate) {
        return nil;
    }

    id overlayPanel = nil;
    @try {
        overlayPanel = [appDelegate valueForKey:@"overlayPanel"];
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (![overlayPanel isKindOfClass:[SPOverlayPanel class]]) {
        return nil;
    }
    return (SPOverlayPanel *)overlayPanel;
}

- (void)showRuntimeOverlayPreview {
    SPOverlayPanel *overlayPanel = [self runtimeOverlayPanel];
    if (!overlayPanel) return;

    NSInteger fontSize = clampedOverlayFontSizeValue(lround(self.overlayFontSizeSlider.doubleValue));
    NSInteger bottomMargin = clampedOverlayBottomMarginValue(lround(self.overlayBottomMarginSlider.doubleValue));
    NSString *fontFamily = [self selectedOverlayFontFamilyValue];
    BOOL limitVisibleLines = self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
    NSInteger maxVisibleLines = [self selectedOverlayMaxVisibleLinesValue];
    [overlayPanel showPreviewWithText:kOverlayPreviewSampleText
                             fontSize:(CGFloat)fontSize
                           fontFamily:fontFamily
                         bottomMargin:(CGFloat)bottomMargin
                    limitVisibleLines:limitVisibleLines
                      maxVisibleLines:maxVisibleLines];
}

- (void)hideRuntimeOverlayPreview {
    [[self runtimeOverlayPanel] hidePreview];
}

- (void)syncOverlayPreviewFromControls {
    [self updateOverlayLineLimitControlsEnabled];
    [self updateOverlayControlValueLabels];
    [self showRuntimeOverlayPreview];
}

- (void)overlayControlChanged:(id)sender {
    [self syncOverlayPreviewFromControls];
}

- (void)resetOverlaySettings:(id)sender {
    [self selectOverlayFontFamilyValue:kOverlayFontFamilyDefault];
    self.overlayFontSizeSlider.integerValue = kOverlayFontSizeDefault;
    self.overlayBottomMarginSlider.integerValue = kOverlayBottomMarginDefault;
    self.overlayLimitVisibleLinesSwitch.state = kOverlayLimitVisibleLinesDefault ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectOverlayMaxVisibleLinesValue:kOverlayMaxVisibleLinesDefault];
    [self syncOverlayPreviewFromControls];
}

- (NSView *)buildHotkeyPane {
    CGFloat paneWidth = 600;
    CGFloat cardWidth = paneWidth - 48;
    CGFloat cardSpacing = 16.0;
    CGFloat topPad = 24.0;

    // ── Trigger Key ──
    self.hotkeyPopup = [self hotkeyPresetPopup];
    self.hotkeyPopup.target = self;
    self.hotkeyPopup.action = @selector(triggerHotkeyChanged:);
    self.recordTriggerHotkeyButton = [NSButton buttonWithTitle:@"Record" target:self action:@selector(recordTriggerHotkey:)];
    self.recordTriggerHotkeyButton.bezelStyle = NSBezelStyleRounded;
    self.recordTriggerHotkeyButton.frame = NSMakeRect(0, 0, 70, 28);
    self.resetTriggerHotkeyButton = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetTriggerHotkey:)];
    self.resetTriggerHotkeyButton.bezelStyle = NSBezelStyleRounded;
    self.resetTriggerHotkeyButton.frame = NSMakeRect(0, 0, 58, 28);
    NSView *triggerShortcutControl = [self hotkeyPickerControlWithPopup:self.hotkeyPopup
                                                           recordButton:self.recordTriggerHotkeyButton
                                                            resetButton:self.resetTriggerHotkeyButton];

    // ── Trigger Mode ──
    self.triggerModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
    [self.triggerModePopup addItemsWithTitles:@[
        @"Hold (Press & Hold)",
        @"Toggle (Tap to Start/Stop)",
    ]];
    [self.triggerModePopup itemAtIndex:0].representedObject = @"hold";
    [self.triggerModePopup itemAtIndex:1].representedObject = @"toggle";

    // ── Trigger card ──
    NSView *triggerCard = [self cardWithTitle:@"Trigger" rows:@[
        [self cardRowWithLabel:@"Trigger Shortcut" control:triggerShortcutControl],
        [self cardRowWithLabel:@"Trigger Mode" control:self.triggerModePopup],
    ] width:cardWidth];

    // ── Feedback Sounds ──
    self.startSoundCheckbox = [self settingsSwitchWithAction:NULL];
    self.stopSoundCheckbox = [self settingsSwitchWithAction:NULL];
    self.errorSoundCheckbox = [self settingsSwitchWithAction:NULL];

    NSView *feedbackCard = [self cardWithTitle:@"Feedback Sounds" rows:@[
        [self cardRowWithLabel:@"Recording starts" control:self.startSoundCheckbox],
        [self cardRowWithLabel:@"Recording stops" control:self.stopSoundCheckbox],
        [self cardRowWithLabel:@"Error occurs" control:self.errorSoundCheckbox],
    ] width:cardWidth];

    // ── Layout ──
    CGFloat triggerH = triggerCard.frame.size.height;
    CGFloat feedbackH = feedbackCard.frame.size.height;
    CGFloat contentHeight = topPad + triggerH + cardSpacing + feedbackH + 56;

    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat y = contentHeight - topPad;

    y -= triggerH;
    triggerCard.frame = NSMakeRect(24, y, cardWidth, triggerH);
    [pane addSubview:triggerCard];
    // Fix control positions — the card's child (index 1) is the white card view
    NSView *triggerCardBody = triggerCard.subviews.count > 1 ? triggerCard.subviews[1] : triggerCard.subviews[0];
    [self layoutCardRowControls:triggerCardBody width:cardWidth];

    y -= cardSpacing + feedbackH;
    feedbackCard.frame = NSMakeRect(24, y, cardWidth, feedbackH);
    [pane addSubview:feedbackCard];
    NSView *feedbackCardBody = feedbackCard.subviews.count > 1 ? feedbackCard.subviews[1] : feedbackCard.subviews[0];
    [self layoutCardRowControls:feedbackCardBody width:cardWidth];

    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSPopUpButton *)hotkeyPresetPopup {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26) pullsDown:NO];
    NSArray<NSString *> *titles = @[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
        @"Left Control (\u2303)",
        @"Right Control (\u2303)",
    ];
    NSArray<NSString *> *values = @[
        @"fn",
        @"left_option",
        @"right_option",
        @"left_command",
        @"right_command",
        @"left_control",
        @"right_control",
    ];
    [popup addItemsWithTitles:titles];
    for (NSInteger idx = 0; idx < (NSInteger)values.count; idx++) {
        [popup itemAtIndex:idx].representedObject = values[idx];
    }
    return popup;
}

- (NSView *)hotkeyPickerControlWithPopup:(NSPopUpButton *)popup
                            recordButton:(NSButton *)button
                             resetButton:(NSButton *)resetButton {
    CGFloat spacing = 6.0;
    CGFloat width = popup.frame.size.width + spacing + button.frame.size.width + spacing + resetButton.frame.size.width;
    CGFloat height = MAX(popup.frame.size.height, button.frame.size.height);
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

    popup.frame = NSMakeRect(0, floor((height - popup.frame.size.height) / 2.0), popup.frame.size.width, popup.frame.size.height);
    button.frame = NSMakeRect(CGRectGetMaxX(popup.frame) + spacing,
                              floor((height - button.frame.size.height) / 2.0),
                              button.frame.size.width,
                              button.frame.size.height);
    resetButton.frame = NSMakeRect(CGRectGetMaxX(button.frame) + spacing,
                                   floor((height - resetButton.frame.size.height) / 2.0),
                                   resetButton.frame.size.width,
                                   resetButton.frame.size.height);
    [container addSubview:popup];
    [container addSubview:button];
    [container addSubview:resetButton];
    return container;
}

- (void)setRuntimeHotkeyMonitoringSuspended:(BOOL)suspended {
    id appDelegate = NSApp.delegate;
    if (!appDelegate) return;

    id monitor = nil;
    @try {
        monitor = [appDelegate valueForKey:@"hotkeyMonitor"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if ([monitor respondsToSelector:@selector(setSuspended:)]) {
        [monitor setSuspended:suspended];
    }
}

- (void)selectHotkeyValue:(NSString *)value inPopup:(NSPopUpButton *)popup {
    NSString *normalizedValue = normalizedHotkeyValue(value);
    if (hotkeyValueUsesCustomPopupItem(normalizedValue)) {
        ensureCustomHotkeyInPopup(popup, normalizedValue);
        return;
    }

    NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
    for (NSMenuItem *item in popup.itemArray) {
        NSString *representedObject = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : nil;
        if (representedObject.length > 0 && ![presetHotkeyValues() containsObject:representedObject]) {
            [itemsToRemove addObject:item];
        }
    }
    for (NSMenuItem *item in itemsToRemove) {
        [popup.menu removeItem:item];
    }

    for (NSMenuItem *item in popup.itemArray) {
        if ([[item.representedObject description] isEqualToString:normalizedValue]) {
            [popup selectItem:item];
            return;
        }
    }

    [popup selectItemAtIndex:0];
}

- (void)triggerHotkeyChanged:(id)sender {
}

- (void)updateHotkeyRecordingButtons {
    BOOL recordingTrigger = [self.recordingHotkeyTarget isEqualToString:@"trigger"];

    self.recordTriggerHotkeyButton.enabled = YES;
    self.resetTriggerHotkeyButton.enabled = !recordingTrigger;
    [self.recordTriggerHotkeyButton setTitle:(recordingTrigger ? @"Press..." : @"Record")];
}

- (NSString *)recordedHotkeyValueFromEvent:(NSEvent *)event {
    NSInteger keyCode = event.keyCode;
    switch (keyCode) {
        case 54:
        case 55:
        case 56:
        case 57:
        case 58:
        case 59:
        case 60:
        case 61:
        case 62:
        case 63:
            return nil;
        default:
            break;
    }

    NSUInteger flags = event.modifierFlags & (NSEventModifierFlagCommand |
                                              NSEventModifierFlagOption |
                                              NSEventModifierFlagControl |
                                              NSEventModifierFlagShift |
                                              NSEventModifierFlagFunction);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ((flags & NSEventModifierFlagCommand) != 0) [parts addObject:@"command"];
    if ((flags & NSEventModifierFlagOption) != 0) [parts addObject:@"option"];
    if ((flags & NSEventModifierFlagControl) != 0) [parts addObject:@"control"];
    if ((flags & NSEventModifierFlagShift) != 0) [parts addObject:@"shift"];
    if ((flags & NSEventModifierFlagFunction) != 0) [parts addObject:@"fn"];
    [parts addObject:[NSString stringWithFormat:@"%ld", (long)keyCode]];
    return normalizedHotkeyValue([parts componentsJoinedByString:@"+"]);
}

- (void)endHotkeyRecording {
    if (self.hotkeyRecordingMonitor) {
        [NSEvent removeMonitor:self.hotkeyRecordingMonitor];
        self.hotkeyRecordingMonitor = nil;
    }
    self.recordingHotkeyTarget = nil;
    [self setRuntimeHotkeyMonitoringSuspended:NO];
    [self updateHotkeyRecordingButtons];
}

- (void)beginHotkeyRecordingForTarget:(NSString *)target popup:(NSPopUpButton *)popup {
    [self endHotkeyRecording];

    self.recordingHotkeyTarget = target;
    [self setRuntimeHotkeyMonitoringSuspended:YES];
    [self updateHotkeyRecordingButtons];

    __weak typeof(self) weakSelf = self;
    self.hotkeyRecordingMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskFlagsChanged)
                                                                        handler:^NSEvent *(NSEvent *event) {
        if (![weakSelf.recordingHotkeyTarget isEqualToString:target]) {
            return event;
        }

        if (event.type == NSEventTypeKeyDown && event.keyCode == 53) {
            [weakSelf endHotkeyRecording];
            return nil;
        }

        if (event.type != NSEventTypeKeyDown || [event isARepeat]) {
            return nil;
        }

        NSString *recordedValue = [weakSelf recordedHotkeyValueFromEvent:event];
        if (recordedValue.length == 0) {
            return nil;
        }

        [weakSelf selectHotkeyValue:recordedValue inPopup:popup];
        [weakSelf endHotkeyRecording];
        return nil;
    }];
}

- (void)recordTriggerHotkey:(id)sender {
    [self beginHotkeyRecordingForTarget:@"trigger" popup:self.hotkeyPopup];
}

- (void)resetTriggerHotkey:(id)sender {
    [self endHotkeyRecording];
    [self selectHotkeyValue:@"fn" inPopup:self.hotkeyPopup];
}

- (NSView *)buildDictionaryPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];
    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;

    CGFloat y = contentHeight - 30.0;

    // Description
    NSTextField *desc = [self addSettingsDescriptionText:@"User dictionary \u2014 one term per line. These terms are prioritized during LLM correction. Lines starting with # are comments."
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];

    NSTextField *sectionTitle = [self sectionTitleLabel:@"Dictionary"
                                                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0), contentW, 20)];
    [pane addSubview:sectionTitle];

    // Text editor
    CGFloat editorCardY = 56.0;
    CGFloat editorTopY = NSMinY(sectionTitle.frame) - 12.0;
    CGFloat editorHeight = editorTopY - editorCardY;
    NSView *editorCard = [self surfaceCardViewWithFrame:NSMakeRect(contentX, editorCardY, contentW, editorHeight)];
    [pane addSubview:editorCard];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, contentW - 24, editorHeight - 24)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;

    self.dictionaryTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentW - 24, editorHeight - 24)];
    self.dictionaryTextView.minSize = NSMakeSize(0, editorHeight - 24);
    self.dictionaryTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.dictionaryTextView.verticallyResizable = YES;
    self.dictionaryTextView.horizontallyResizable = NO;
    self.dictionaryTextView.autoresizingMask = NSViewWidthSizable;
    self.dictionaryTextView.textContainer.containerSize = NSMakeSize(contentW - 24, FLT_MAX);
    self.dictionaryTextView.textContainer.widthTracksTextView = YES;
    self.dictionaryTextView.textContainerInset = NSMakeSize(8, 10);
    self.dictionaryTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.dictionaryTextView.allowsUndo = YES;

    scrollView.documentView = self.dictionaryTextView;
    [editorCard addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildSystemPromptPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];
    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;

    CGFloat y = contentHeight - 30.0;

    // Description
    NSTextField *desc = [self addSettingsDescriptionText:@"System prompt sent to the LLM for text correction. Edit to customize behavior."
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];

    NSTextField *sectionTitle = [self sectionTitleLabel:@"System Prompt"
                                                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0), contentW, 20)];
    [pane addSubview:sectionTitle];

    // Text editor
    CGFloat editorCardY = 56.0;
    CGFloat editorTopY = NSMinY(sectionTitle.frame) - 12.0;
    CGFloat editorHeight = editorTopY - editorCardY;
    NSView *editorCard = [self surfaceCardViewWithFrame:NSMakeRect(contentX, editorCardY, contentW, editorHeight)];
    [pane addSubview:editorCard];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, contentW - 24, editorHeight - 24)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;

    self.systemPromptTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentW - 24, editorHeight - 24)];
    self.systemPromptTextView.minSize = NSMakeSize(0, editorHeight - 24);
    self.systemPromptTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.systemPromptTextView.verticallyResizable = YES;
    self.systemPromptTextView.horizontallyResizable = NO;
    self.systemPromptTextView.autoresizingMask = NSViewWidthSizable;
    self.systemPromptTextView.textContainer.containerSize = NSMakeSize(contentW - 24, FLT_MAX);
    self.systemPromptTextView.textContainer.widthTracksTextView = YES;
    self.systemPromptTextView.textContainerInset = NSMakeSize(8, 10);
    self.systemPromptTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.systemPromptTextView.allowsUndo = YES;

    scrollView.documentView = self.systemPromptTextView;
    [editorCard addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

// ─── Templates Pane ────────────────────────────────────────────────

- (NSView *)buildTemplatesPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 568;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat contentX = 24.0;
    CGFloat contentW = paneWidth - 48.0;
    CGFloat y = contentHeight - 30.0;

    NSTextField *desc = [self addSettingsDescriptionText:@"Manage overlay templates. Reorder them, control visibility, and edit each prompt here."
                                                  toPane:pane
                                                   topY:y
                                                      x:contentX
                                                  width:contentW];
    y = NSMinY(desc.frame) - 16.0;

    self.templatesEnabledSwitch = [self settingsSwitchWithAction:NULL];
    NSView *visibilityCard = [self settingsToggleCardWithFrame:NSMakeRect(contentX, y - 48, contentW, 48)
                                                         title:@"Show template buttons in overlay"
                                                        toggle:self.templatesEnabledSwitch];
    [pane addSubview:visibilityCard];

    CGFloat sectionTitleY = NSMinY(visibilityCard.frame) - 44.0;
    CGFloat mainCardY = 60.0;
    CGFloat mainCardH = sectionTitleY - mainCardY - 12.0;
    CGFloat listW = 214.0;
    CGFloat cardGap = 16.0;
    CGFloat editorW = contentW - listW - cardGap;
    CGFloat editorX = contentX + listW + cardGap;

    NSTextField *listTitle = [self sectionTitleLabel:@"Template Library"
                                               frame:NSMakeRect(contentX, sectionTitleY, listW, 20)];
    [pane addSubview:listTitle];

    NSTextField *editorTitle = [self sectionTitleLabel:@"Template Editor"
                                                 frame:NSMakeRect(editorX, sectionTitleY, editorW, 20)];
    [pane addSubview:editorTitle];

    NSView *listCard = [self surfaceCardViewWithFrame:NSMakeRect(contentX, mainCardY, listW, mainCardH)];
    [pane addSubview:listCard];

    NSView *editorCard = [self surfaceCardViewWithFrame:NSMakeRect(editorX, mainCardY, editorW, mainCardH)];
    [pane addSubview:editorCard];

    CGFloat headerH = 34.0;
    CGFloat footerH = 34.0;

    NSTextField *libraryCaption = [NSTextField labelWithString:@"Templates"];
    libraryCaption.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    libraryCaption.textColor = NSColor.labelColor;
    libraryCaption.frame = NSMakeRect(14, mainCardH - headerH + 9, 120, 18);
    [listCard addSubview:libraryCaption];

    NSBox *headerSeparator = [[NSBox alloc] initWithFrame:NSMakeRect(0, mainCardH - headerH, listW, 1)];
    headerSeparator.boxType = NSBoxSeparator;
    [listCard addSubview:headerSeparator];

    NSBox *footerSeparator = [[NSBox alloc] initWithFrame:NSMakeRect(0, footerH, listW, 1)];
    footerSeparator.boxType = NSBoxSeparator;
    [listCard addSubview:footerSeparator];

    self.templatePrimaryActionsControl = [self templateActionSegmentedControlWithSymbols:@[@"plus", @"minus"]
                                                                                toolTips:@[@"Add template", @"Remove selected template"]
                                                                                  action:@selector(handleTemplatePrimaryActions:)];
    self.templatePrimaryActionsControl.frame = NSMakeRect(12, 5, 50, 24);
    [listCard addSubview:self.templatePrimaryActionsControl];

    self.templateReorderActionsControl = [self templateActionSegmentedControlWithSymbols:@[@"arrow.up", @"arrow.down"]
                                                                                 toolTips:@[@"Move selected template up", @"Move selected template down"]
                                                                                   action:@selector(handleTemplateReorderActions:)];
    self.templateReorderActionsControl.frame = NSMakeRect(listW - 12 - 50, 5, 50, 24);
    [listCard addSubview:self.templateReorderActionsControl];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, footerH + 10, listW - 20, mainCardH - headerH - footerH - 20)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.wantsLayer = YES;
    scrollView.layer.cornerRadius = 8.0;
    scrollView.layer.borderWidth = 1.0;
    scrollView.layer.borderColor = NSColor.separatorColor.CGColor;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;
    [listCard addSubview:scrollView];

    self.templatesTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.title = @"Template";
    col.width = scrollView.bounds.size.width;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.templatesTableView addTableColumn:col];
    self.templatesTableView.headerView = nil;
    self.templatesTableView.rowHeight = 34.0;
    self.templatesTableView.intercellSpacing = NSMakeSize(0, 0);
    self.templatesTableView.backgroundColor = [NSColor clearColor];
    self.templatesTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.templatesTableView.focusRingType = NSFocusRingTypeNone;
    self.templatesTableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.templatesTableView.delegate = (id)self;
    self.templatesTableView.dataSource = (id)self;
    scrollView.documentView = self.templatesTableView;

    NSTextField *nameLabel = [self sectionTitleLabel:@"Name" frame:NSMakeRect(16, mainCardH - 34, editorW - 32, 18)];
    [editorCard addSubview:nameLabel];

    self.templateNameField = [self formTextField:NSMakeRect(16, mainCardH - 64, editorW - 32, 24) placeholder:@"Template name"];
    self.templateNameField.delegate = self;
    [editorCard addSubview:self.templateNameField];

    self.templateItemEnabledSwitch = [self settingsSwitchWithAction:@selector(toggleSelectedTemplateEnabled:)
                                                        controlSize:NSControlSizeSmall];
    CGFloat templateItemToggleW = self.templateItemEnabledSwitch.frame.size.width;
    CGFloat templateItemToggleH = self.templateItemEnabledSwitch.frame.size.height;
    CGFloat templateVisibilityCenterY = mainCardH - 86.0;

    NSTextField *templateVisibilityLabel = [self settingsRowLabelWithString:@"Visible in overlay"];
    templateVisibilityLabel.frame = NSMakeRect(16,
                                               floor(templateVisibilityCenterY - 10.0),
                                               editorW - templateItemToggleW - 44.0,
                                               20);
    [editorCard addSubview:templateVisibilityLabel];

    self.templateItemEnabledSwitch.frame = NSMakeRect(editorW - 16 - templateItemToggleW,
                                                      floor(templateVisibilityCenterY - (templateItemToggleH / 2.0)),
                                                      templateItemToggleW,
                                                      templateItemToggleH);
    [editorCard addSubview:self.templateItemEnabledSwitch];

    NSTextField *promptLabel = [self sectionTitleLabel:@"Prompt" frame:NSMakeRect(16, mainCardH - 124, editorW - 32, 18)];
    [editorCard addSubview:promptLabel];

    NSScrollView *promptScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, editorW - 32, mainCardH - 146)];
    promptScroll.hasVerticalScroller = YES;
    promptScroll.borderType = NSNoBorder;
    promptScroll.drawsBackground = NO;
    promptScroll.wantsLayer = YES;
    promptScroll.layer.cornerRadius = 8.0;
    promptScroll.layer.borderWidth = 1.0;
    promptScroll.layer.borderColor = NSColor.separatorColor.CGColor;

    self.templatePromptTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, editorW - 48, mainCardH - 146)];
    self.templatePromptTextView.minSize = NSMakeSize(0, mainCardH - 146);
    self.templatePromptTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.templatePromptTextView.verticallyResizable = YES;
    self.templatePromptTextView.horizontallyResizable = NO;
    self.templatePromptTextView.textContainerInset = NSMakeSize(8, 10);
    self.templatePromptTextView.textContainer.containerSize = NSMakeSize(editorW - 48, CGFLOAT_MAX);
    self.templatePromptTextView.textContainer.widthTracksTextView = YES;
    self.templatePromptTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.templatePromptTextView.allowsUndo = YES;
    self.templatePromptTextView.delegate = self;
    promptScroll.documentView = self.templatePromptTextView;
    [editorCard addSubview:promptScroll];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

#pragma mark - Templates Table Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.templatesTableView) {
        return (NSInteger)self.templatesData.count;
    }
    if (tableView == self.llmProfileTableView) {
        return (NSInteger)self.llmProfileOrder.count;
    }
    return 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.llmProfileTableView) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:@"LlmProfileCell" owner:self];
        NSTextField *titleLabel = nil;
        NSTextField *subtitleLabel = nil;
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, tableView.rowHeight)];
            cell.identifier = @"LlmProfileCell";
            cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

            titleLabel = [NSTextField labelWithString:@""];
            titleLabel.identifier = @"LlmProfileTitle";
            titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
            titleLabel.frame = NSMakeRect(10, 22, tableColumn.width - 20, 18);
            titleLabel.autoresizingMask = NSViewWidthSizable;
            [cell addSubview:titleLabel];
            cell.textField = titleLabel;

            subtitleLabel = [NSTextField labelWithString:@""];
            subtitleLabel.identifier = @"LlmProfileSubtitle";
            subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            subtitleLabel.font = [NSFont systemFontOfSize:11];
            subtitleLabel.textColor = [NSColor secondaryLabelColor];
            subtitleLabel.frame = NSMakeRect(10, 4, tableColumn.width - 20, 14);
            subtitleLabel.autoresizingMask = NSViewWidthSizable;
            [cell addSubview:subtitleLabel];
        } else {
            for (NSView *sub in cell.subviews) {
                if ([sub.identifier isEqualToString:@"LlmProfileTitle"]) titleLabel = (NSTextField *)sub;
                else if ([sub.identifier isEqualToString:@"LlmProfileSubtitle"]) subtitleLabel = (NSTextField *)sub;
            }
        }

        if (row >= 0 && row < (NSInteger)self.llmProfileOrder.count) {
            NSString *profileId = self.llmProfileOrder[row];
            NSDictionary *profile = self.llmProfiles[profileId];
            NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] && [profile[@"name"] length] > 0
                ? profile[@"name"] : profileId;
            NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]] ? profile[@"provider"] : @"openai";
            titleLabel.stringValue = name;
            subtitleLabel.stringValue = [self prettyNameForLlmProvider:provider];
        }
        return cell;
    }

    if (tableView != self.templatesTableView) return nil;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"TemplateCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, tableView.rowHeight)];
        cell.identifier = @"TemplateCell";
        cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSTextField *titleLabel = [NSTextField labelWithString:@""];
        titleLabel.identifier = @"TemplateTitleLabel";
        titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        titleLabel.alignment = NSTextAlignmentLeft;
        titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        titleLabel.textColor = NSColor.labelColor;
        titleLabel.autoresizingMask = NSViewWidthSizable;
        titleLabel.frame = NSMakeRect(12, 7, tableColumn.width - 24, 20);
        cell.textField = titleLabel;
        [cell addSubview:titleLabel];
    }

    if (row < (NSInteger)self.templatesData.count) {
        NSDictionary *tmpl = self.templatesData[row];
        NSString *name = tmpl[@"name"] ?: @"Untitled";
        BOOL enabled = [self isTemplateEnabled:tmpl];

        NSTextField *titleLabel = nil;
        for (NSView *subview in cell.subviews) {
            if ([subview.identifier isEqualToString:@"TemplateTitleLabel"]) {
                titleLabel = (NSTextField *)subview;
            }
        }

        titleLabel.stringValue = name;
        titleLabel.frame = NSMakeRect(12, 7, tableColumn.width - 24, 20);
        titleLabel.textColor = enabled ? NSColor.labelColor : NSColor.secondaryLabelColor;
        titleLabel.alphaValue = enabled ? 1.0 : 0.6;
    }
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    if (tableView == self.templatesTableView) {
        return [[SPTemplateRowView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, tableView.rowHeight)];
    }
    if (tableView == self.llmProfileTableView) {
        return [[SPLlmProfileRowView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, tableView.rowHeight)];
    }
    return nil;
}

- (NSString *)resolvedPromptTextForTemplate:(NSDictionary *)templateData {
    id inlinePrompt = templateData[@"system_prompt"];
    if ([inlinePrompt isKindOfClass:[NSString class]]) {
        NSString *inlineText = (NSString *)inlinePrompt;
        NSString *trimmedInlineText = [inlineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedInlineText.length > 0) {
            return inlineText;
        }
    }

    id promptPath = templateData[@"system_prompt_path"];
    if ([promptPath isKindOfClass:[NSString class]] && [promptPath length] > 0) {
        NSString *path = (NSString *)promptPath;
        NSString *resolvedPath = path.isAbsolutePath ? path : [configDirPath() stringByAppendingPathComponent:path];
        NSString *filePrompt = [NSString stringWithContentsOfFile:resolvedPath
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
        if ([filePrompt isKindOfClass:[NSString class]]) {
            NSString *trimmedFilePrompt = [filePrompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmedFilePrompt.length > 0) {
                return filePrompt;
            }
        }
    }

    return @"";
}

- (NSString *)editablePromptTextForTemplate:(NSMutableDictionary *)templateData {
    id editablePrompt = templateData[kTemplateEditablePromptKey];
    if ([editablePrompt isKindOfClass:[NSString class]]) {
        return editablePrompt ?: @"";
    }

    NSString *resolvedPrompt = [self resolvedPromptTextForTemplate:templateData];
    templateData[kTemplateEditablePromptKey] = resolvedPrompt ?: @"";
    if (![templateData[kTemplateOriginalPromptKey] isKindOfClass:[NSString class]]) {
        templateData[kTemplateOriginalPromptKey] = resolvedPrompt ?: @"";
    }
    return resolvedPrompt ?: @"";
}

- (BOOL)isTemplateEnabled:(NSDictionary *)templateData {
    id enabledValue = templateData[@"enabled"];
    return ![enabledValue isKindOfClass:[NSNumber class]] || [enabledValue boolValue];
}

- (NSString *)trimmedResolvedPromptTextForTemplate:(NSDictionary *)templateData {
    NSString *resolvedPrompt = [self resolvedPromptTextForTemplate:templateData] ?: @"";
    return [resolvedPrompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// ─── Template List: selection only loads, NEVER saves back automatically ───
//
// Design: templatesData is the source of truth. The editor fields are just
// a view into one entry. We sync editor→data ONLY on explicit actions:
// (1) user clicks Save button  (2) user clicks + to add  (3) switching tabs
//
// tableViewSelectionDidChange just loads the new row into the editor.
// It first writes back the editor content for the OLD row, which is safe
// because selectedTemplateIndex still points to the old row at that moment.

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.llmProfileTableView) {
        if (self.suppressLlmProfileSelection) return;
        NSInteger row = self.llmProfileTableView.selectedRow;
        if (row < 0 || row >= (NSInteger)self.llmProfileOrder.count) return;
        NSString *newId = self.llmProfileOrder[row];
        if ([newId isEqualToString:self.activeLlmProfileId]) return;

        // Flush editor fields into the OLD active profile before switching
        [self syncActiveLlmProfileFromFields];
        self.activeLlmProfileId = newId;
        [self applyActiveLlmProfileToFields];
        [self updateLlmFieldsEnabled];
        self.llmTestResultLabel.stringValue = @"";
        return;
    }

    if (notification.object != self.templatesTableView) return;
    if (self.suppressTemplateSync) return;

    NSInteger newRow = self.templatesTableView.selectedRow;
    if (newRow == self.selectedTemplateIndex) return;

    // Write editor content back to the OLD row before loading the new one
    [self flushEditorToIndex:self.selectedTemplateIndex];

    self.selectedTemplateIndex = newRow;
    [self loadEditorFromIndex:newRow];
    [self updateTemplateActionButtons];
}

/// Write current editor fields into templatesData[index]. Safe to call with -1.
- (void)flushEditorToIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.templatesData.count) return;
    if (!self.templateNameField) return;
    if (!self.templateEditorDirty) return;

    NSMutableDictionary *templateData = self.templatesData[index];
    NSString *editedPrompt = self.templatePromptTextView.string ?: @"";

    templateData[@"name"] = self.templateNameField.stringValue ?: @"";
    templateData[kTemplateEditablePromptKey] = editedPrompt;

    NSString *originalPrompt = [templateData[kTemplateOriginalPromptKey] isKindOfClass:[NSString class]]
        ? templateData[kTemplateOriginalPromptKey]
        : [self resolvedPromptTextForTemplate:templateData];
    NSString *inlinePrompt = [templateData[@"system_prompt"] isKindOfClass:[NSString class]]
        ? templateData[@"system_prompt"]
        : nil;
    NSString *promptPath = [templateData[@"system_prompt_path"] isKindOfClass:[NSString class]]
        ? templateData[@"system_prompt_path"]
        : nil;

    // If this template references an external file, preserve that relationship.
    // Write changes back to the file rather than silently converting to inline.
    if (inlinePrompt.length == 0 && promptPath.length > 0) {
        if (![editedPrompt isEqualToString:(originalPrompt ?: @"")]) {
            NSString *resolvedPath = promptPath.isAbsolutePath
                ? promptPath
                : [configDirPath() stringByAppendingPathComponent:promptPath];
            NSError *writeError = nil;
            [editedPrompt writeToFile:resolvedPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
            if (writeError) {
                NSLog(@"[Koe] Failed to write template file %@: %@", resolvedPath, writeError.localizedDescription);
            }
            templateData[kTemplateOriginalPromptKey] = editedPrompt;
        }
        [templateData removeObjectForKey:@"system_prompt"];
        self.templateEditorDirty = NO;
        return;
    }

    templateData[@"system_prompt"] = editedPrompt;
    [templateData removeObjectForKey:@"system_prompt_path"];
    templateData[kTemplateOriginalPromptKey] = editedPrompt;
    self.templateEditorDirty = NO;
}

/// Load templatesData[index] into the editor fields. -1 clears everything.
- (void)loadEditorFromIndex:(NSInteger)index {
    BOOL previousSuppress = self.suppressTemplateSync;
    self.suppressTemplateSync = YES;

    if (index >= 0 && index < (NSInteger)self.templatesData.count) {
        NSMutableDictionary *tmpl = self.templatesData[index];
        self.templateNameField.stringValue = tmpl[@"name"] ?: @"";
        self.templateItemEnabledSwitch.state = [self isTemplateEnabled:tmpl] ? NSControlStateValueOn : NSControlStateValueOff;
        self.templatePromptTextView.string = [self editablePromptTextForTemplate:tmpl];
        self.templateNameField.enabled = YES;
        self.templateItemEnabledSwitch.enabled = YES;
        self.templatePromptTextView.editable = YES;
    } else {
        self.templateNameField.stringValue = @"";
        self.templateItemEnabledSwitch.state = NSControlStateValueOff;
        self.templatePromptTextView.string = @"";
        self.templateNameField.enabled = NO;
        self.templateItemEnabledSwitch.enabled = NO;
        self.templatePromptTextView.editable = NO;
    }

    self.templateEditorDirty = NO;
    self.suppressTemplateSync = previousSuppress;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.llmProfileNameField) {
        NSMutableDictionary *profile = [self activeLlmProfile];
        if (!profile) return;
        profile[@"name"] = self.llmProfileNameField.stringValue ?: @"";
        NSInteger row = [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
        if (row != NSNotFound) {
            [self.llmProfileTableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                                                columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        }
        return;
    }

    if (self.suppressTemplateSync) return;
    if (notification.object != self.templateNameField) return;
    if (self.selectedTemplateIndex < 0 || self.selectedTemplateIndex >= (NSInteger)self.templatesData.count) return;

    self.templateEditorDirty = YES;
    self.templatesData[self.selectedTemplateIndex][@"name"] = self.templateNameField.stringValue ?: @"";

    NSIndexSet *rows = [NSIndexSet indexSetWithIndex:(NSUInteger)self.selectedTemplateIndex];
    NSIndexSet *columns = [NSIndexSet indexSetWithIndex:0];
    [self.templatesTableView reloadDataForRowIndexes:rows columnIndexes:columns];
}

- (void)textDidChange:(NSNotification *)notification {
    if (self.suppressTemplateSync) return;
    if (notification.object != self.templatePromptTextView) return;

    self.templateEditorDirty = YES;
}

- (void)toggleSelectedTemplateEnabled:(id)sender {
    if (self.selectedTemplateIndex < 0 || self.selectedTemplateIndex >= (NSInteger)self.templatesData.count) return;

    self.templatesData[self.selectedTemplateIndex][@"enabled"] = @(self.templateItemEnabledSwitch.state == NSControlStateValueOn);
    NSIndexSet *rows = [NSIndexSet indexSetWithIndex:(NSUInteger)self.selectedTemplateIndex];
    NSIndexSet *columns = [NSIndexSet indexSetWithIndex:0];
    [self.templatesTableView reloadDataForRowIndexes:rows columnIndexes:columns];
}

/// Flush editor, then reload table (used by Save button & tab switch).
- (void)saveCurrentTemplateEdits {
    [self flushEditorToIndex:self.selectedTemplateIndex];
    [self reindexTemplateShortcuts];
}

- (void)updateTemplateActionButtons {
    BOOL canAdd = self.templatesData.count < 9;
    BOOL hasSelection = self.templatesTableView.selectedRow >= 0;
    BOOL canMoveUp = hasSelection && self.templatesTableView.selectedRow > 0;
    BOOL canMoveDown = hasSelection && self.templatesTableView.selectedRow < (NSInteger)self.templatesData.count - 1;

    [self.templatePrimaryActionsControl setEnabled:canAdd forSegment:0];
    [self.templatePrimaryActionsControl setEnabled:hasSelection forSegment:1];
    [self.templateReorderActionsControl setEnabled:canMoveUp forSegment:0];
    [self.templateReorderActionsControl setEnabled:canMoveDown forSegment:1];
}

- (void)reindexTemplateShortcuts {
    [self.templatesData enumerateObjectsUsingBlock:^(NSMutableDictionary *templateData, NSUInteger idx, BOOL *stop) {
        templateData[@"shortcut"] = @((NSInteger)idx + 1);
        if (![templateData[@"enabled"] isKindOfClass:[NSNumber class]]) {
            templateData[@"enabled"] = @YES;
        }
    }];
}

- (void)reloadTemplateTableSelectingRow:(NSInteger)row {
    NSInteger selectedRow = (row >= 0 && row < (NSInteger)self.templatesData.count) ? row : -1;
    self.selectedTemplateIndex = selectedRow;

    self.suppressTemplateSync = YES;
    [self.templatesTableView reloadData];
    if (selectedRow >= 0) {
        [self.templatesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedRow] byExtendingSelection:NO];
    } else {
        [self.templatesTableView deselectAll:nil];
    }
    self.suppressTemplateSync = NO;

    [self loadEditorFromIndex:selectedRow];
    [self updateTemplateActionButtons];
}

- (NSArray<NSDictionary *> *)serializedTemplatesData {
    [self reindexTemplateShortcuts];
    NSMutableArray<NSDictionary *> *serialized = [NSMutableArray arrayWithCapacity:self.templatesData.count];

    for (NSDictionary *templateData in self.templatesData) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"name"] = [templateData[@"name"] isKindOfClass:[NSString class]] ? templateData[@"name"] : @"";
        result[@"enabled"] = @([self isTemplateEnabled:templateData]);
        result[@"shortcut"] = [templateData[@"shortcut"] isKindOfClass:[NSNumber class]] ? templateData[@"shortcut"] : @0;

        NSString *systemPrompt = [templateData[@"system_prompt"] isKindOfClass:[NSString class]] ? templateData[@"system_prompt"] : nil;
        NSString *systemPromptPath = [templateData[@"system_prompt_path"] isKindOfClass:[NSString class]] ? templateData[@"system_prompt_path"] : nil;
        if (systemPrompt != nil) {
            result[@"system_prompt"] = systemPrompt;
        }
        if (systemPromptPath.length > 0) {
            result[@"system_prompt_path"] = systemPromptPath;
        }

        [serialized addObject:result];
    }

    return serialized;
}

- (BOOL)validateTemplatesDataWithMessage:(NSString **)message {
    if (self.templatesData.count > 9) {
        if (message) *message = @"You can add up to 9 prompt templates.";
        return NO;
    }

    NSMutableSet<NSNumber *> *used = [NSMutableSet set];
    for (NSDictionary *tmpl in self.templatesData) {
        NSNumber *shortcut = [tmpl[@"shortcut"] isKindOfClass:[NSNumber class]] ? tmpl[@"shortcut"] : nil;
        NSInteger value = shortcut.integerValue;
        if (!shortcut || value < 1 || value > 9) {
            if (message) *message = @"Each prompt template needs a shortcut between 1 and 9.";
            return NO;
        }
        if ([used containsObject:@(value)]) {
            if (message) *message = @"Each prompt template shortcut must be unique.";
            return NO;
        }
        if ([self trimmedResolvedPromptTextForTemplate:tmpl].length == 0) {
            if (message) *message = @"Each prompt template needs a non-empty prompt.";
            return NO;
        }
        [used addObject:@(value)];
    }

    return YES;
}

- (void)addTemplate:(id)sender {
    if (self.templatesData.count >= 9) {
        [self showAlert:@"Template limit reached"
                   info:@"You can add up to 9 prompt templates because the overlay only supports number keys 1-9."];
        return;
    }

    [self flushEditorToIndex:self.selectedTemplateIndex];
    [self.templatesData addObject:[NSMutableDictionary dictionaryWithDictionary:@{
        @"name": @"New Template",
        @"enabled": @YES,
        @"shortcut": @((NSInteger)self.templatesData.count + 1),
        @"system_prompt": @"",
        kTemplateEditablePromptKey: @"",
        kTemplateOriginalPromptKey: @"",
    }]];

    NSInteger newRow = (NSInteger)self.templatesData.count - 1;
    [self reindexTemplateShortcuts];
    [self reloadTemplateTableSelectingRow:newRow];
}

- (void)handleTemplatePrimaryActions:(NSSegmentedControl *)sender {
    NSInteger segment = sender.selectedSegment;
    if (segment == 0) {
        [self addTemplate:sender];
    } else if (segment == 1) {
        [self removeTemplate:sender];
    }
}

- (void)handleTemplateReorderActions:(NSSegmentedControl *)sender {
    NSInteger segment = sender.selectedSegment;
    if (segment == 0) {
        [self moveTemplateUp:sender];
    } else if (segment == 1) {
        [self moveTemplateDown:sender];
    }
}

- (void)removeTemplate:(id)sender {
    NSInteger row = self.templatesTableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.templatesData.count) return;

    [self flushEditorToIndex:self.selectedTemplateIndex];
    [self.templatesData removeObjectAtIndex:row];
    [self reindexTemplateShortcuts];

    NSInteger nextSelection = MIN(row, (NSInteger)self.templatesData.count - 1);
    [self reloadTemplateTableSelectingRow:nextSelection];
}

- (void)moveTemplateUp:(id)sender {
    NSInteger row = self.templatesTableView.selectedRow;
    if (row <= 0 || row >= (NSInteger)self.templatesData.count) return;

    [self flushEditorToIndex:self.selectedTemplateIndex];
    NSMutableDictionary *templateData = self.templatesData[row];
    [self.templatesData removeObjectAtIndex:row];
    [self.templatesData insertObject:templateData atIndex:row - 1];
    [self reindexTemplateShortcuts];
    [self reloadTemplateTableSelectingRow:row - 1];
}

- (void)moveTemplateDown:(id)sender {
    NSInteger row = self.templatesTableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.templatesData.count - 1) return;

    [self flushEditorToIndex:self.selectedTemplateIndex];
    NSMutableDictionary *templateData = self.templatesData[row];
    [self.templatesData removeObjectAtIndex:row];
    [self.templatesData insertObject:templateData atIndex:row + 1];
    [self reindexTemplateShortcuts];
    [self reloadTemplateTableSelectingRow:row + 1];
}

- (NSView *)buildAboutPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 308;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    [self applySettingsPaneBackgroundToView:pane];

    CGFloat y = contentHeight - 48;

    // App name
    NSTextField *appName = [NSTextField labelWithString:@"Koe (\u58f0)"];
    appName.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    appName.alignment = NSTextAlignmentCenter;
    appName.frame = NSMakeRect(24, y - 4, paneWidth - 48, 36);
    [pane addSubview:appName];
    y -= 44;

    // Version
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0";
    NSTextField *versionLabel = [self descriptionLabel:[NSString stringWithFormat:@"Version %@ (%@)", version, build]];
    versionLabel.alignment = NSTextAlignmentCenter;
    versionLabel.frame = NSMakeRect(24, y, paneWidth - 48, 20);
    [pane addSubview:versionLabel];
    y -= 32;

    // Description
    NSTextField *desc = [self descriptionLabel:@"A background-first macOS voice input tool.\nPress a hotkey, speak, and the corrected text is pasted into whatever app you\u2019re using."];
    desc.alignment = NSTextAlignmentCenter;
    desc.frame = NSMakeRect(60, y - 10, paneWidth - 120, 40);
    [pane addSubview:desc];
    y -= 56;

    // GitHub button
    NSButton *githubButton = [NSButton buttonWithTitle:@"GitHub Repository" target:self action:@selector(openGitHub:)];
    githubButton.bezelStyle = NSBezelStyleRounded;
    githubButton.image = [NSImage imageWithSystemSymbolName:@"arrow.up.right" accessibilityDescription:nil];
    githubButton.imagePosition = NSImageTrailing;
    githubButton.frame = NSMakeRect((paneWidth - 180) / 2.0, y, 180, 32);
    [pane addSubview:githubButton];
    y -= 40;

    // Documentation link
    NSButton *docsButton = [NSButton buttonWithTitle:@"Documentation" target:self action:@selector(openDocs:)];
    docsButton.bezelStyle = NSBezelStyleRounded;
    docsButton.image = [NSImage imageWithSystemSymbolName:@"arrow.up.right" accessibilityDescription:nil];
    docsButton.imagePosition = NSImageTrailing;
    docsButton.frame = NSMakeRect((paneWidth - 180) / 2.0, y, 180, 32);
    [pane addSubview:docsButton];
    y -= 48;

    // License
    NSTextField *license = [self descriptionLabel:@"MIT License \u00b7 Made with Rust + Objective-C"];
    license.alignment = NSTextAlignmentCenter;
    license.frame = NSMakeRect(24, y, paneWidth - 48, 20);
    [pane addSubview:license];

    return pane;
}

- (void)openGitHub:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/missuo/koe"]];
}

- (void)openDocs:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/missuo/koe/blob/main/README.md"]];
}

// ─── Shared button bar ──────────────────────────────────────────────

- (void)addButtonsToPane:(NSView *)pane atY:(CGFloat)y width:(CGFloat)paneWidth {
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveConfig:)];
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(paneWidth - 32 - 80, y, 80, 28);
    [pane addSubview:saveButton];

    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelSetup:)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\033";
    cancelButton.frame = NSMakeRect(paneWidth - 32 - 80 - 88, y, 80, 28);
    [pane addSubview:cancelButton];
}

// ─── UI Helpers ─────────────────────────────────────────────────────

- (NSTextField *)formLabel:(NSString *)title frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = frame;
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    return label;
}

- (NSTextField *)formTextField:(NSRect)frame placeholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.placeholderString = placeholder;
    field.font = [NSFont systemFontOfSize:13];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.usesSingleLineMode = YES;
    return field;
}

- (NSSlider *)overlaySliderWithMin:(double)minValue max:(double)maxValue action:(SEL)action {
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 228, 24)];
    slider.minValue = minValue;
    slider.maxValue = maxValue;
    slider.numberOfTickMarks = 0;
    slider.continuous = YES;
    slider.target = self;
    slider.action = action;
    return slider;
}

- (NSTextField *)overlayValueLabel {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = [NSColor secondaryLabelColor];
    label.frame = NSMakeRect(0, 0, 54, 18);
    return label;
}

- (NSArray<NSString *> *)availableOverlayFontFamilies {
    if (self.overlayAvailableFontFamilies.count > 0) {
        return self.overlayAvailableFontFamilies;
    }

    NSMutableOrderedSet<NSString *> *families = [NSMutableOrderedSet orderedSet];
    for (NSString *family in [[NSFontManager sharedFontManager] availableFontFamilies]) {
        NSString *normalized = normalizedOverlayFontFamilyValue(family);
        if (!overlayUsesSystemFontFamily(normalized)) {
            [families addObject:normalized];
        }
    }

    NSArray<NSString *> *sortedFamilies = [[families array] sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        return [lhs localizedStandardCompare:rhs];
    }];
    self.overlayAvailableFontFamilies = sortedFamilies;
    return sortedFamilies;
}

- (NSAttributedString *)overlayFontMenuTitleWithLabel:(NSString *)label value:(NSString *)value {
    NSFont *font = overlayFontForFamily(value, 13.0);
    return [[NSAttributedString alloc] initWithString:label
                                           attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor labelColor],
    }];
}

- (NSPopUpButton *)overlayFontFamilyPopupControl {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 290, 26) pullsDown:NO];
    popup.target = self;
    popup.action = @selector(overlayControlChanged:);

    [popup removeAllItems];

    NSMenuItem *systemItem = [[NSMenuItem alloc] initWithTitle:kOverlayFontFamilySystemLabel action:nil keyEquivalent:@""];
    systemItem.representedObject = kOverlayFontFamilyDefault;
    systemItem.attributedTitle = [self overlayFontMenuTitleWithLabel:kOverlayFontFamilySystemLabel value:kOverlayFontFamilyDefault];
    [popup.menu addItem:systemItem];

    for (NSString *family in [self availableOverlayFontFamilies]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:family action:nil keyEquivalent:@""];
        item.representedObject = family;
        item.attributedTitle = [self overlayFontMenuTitleWithLabel:family value:family];
        [popup.menu addItem:item];
    }

    return popup;
}

- (NSPopUpButton *)overlayMaxVisibleLinesPopupControl {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 118.0, 28.0) pullsDown:NO];
    popup.target = self;
    popup.action = @selector(overlayControlChanged:);

    for (NSInteger value = kOverlayMaxVisibleLinesMin; value <= kOverlayMaxVisibleLinesMax; value++) {
        NSString *title = [NSString stringWithFormat:@"%ld lines", (long)value];
        [popup addItemWithTitle:title];
        popup.lastItem.representedObject = @(value);
    }

    [popup selectItemAtIndex:0];
    return popup;
}

- (NSString *)selectedOverlayFontFamilyValue {
    NSString *selectedValue = self.overlayFontFamilyPopup.selectedItem.representedObject;
    return normalizedOverlayFontFamilyValue(selectedValue);
}

- (NSInteger)selectedOverlayMaxVisibleLinesValue {
    NSNumber *selectedValue = [self.overlayMaxVisibleLinesPopup.selectedItem.representedObject isKindOfClass:[NSNumber class]]
        ? self.overlayMaxVisibleLinesPopup.selectedItem.representedObject
        : nil;
    return clampedOverlayMaxVisibleLinesValue(selectedValue.integerValue > 0 ? selectedValue.integerValue : kOverlayMaxVisibleLinesDefault);
}

- (void)selectOverlayFontFamilyValue:(NSString *)value {
    NSString *normalized = normalizedOverlayFontFamilyValue(value);

    for (NSMenuItem *item in self.overlayFontFamilyPopup.itemArray) {
        NSString *representedValue = item.representedObject;
        if (representedValue.length == 0) continue;
        if ([representedValue isEqualToString:normalized]) {
            [self.overlayFontFamilyPopup selectItem:item];
            return;
        }
    }

    [self.overlayFontFamilyPopup selectItemAtIndex:0];
}

- (void)selectOverlayMaxVisibleLinesValue:(NSInteger)value {
    NSInteger clampedValue = clampedOverlayMaxVisibleLinesValue(value);
    for (NSMenuItem *item in self.overlayMaxVisibleLinesPopup.itemArray) {
        NSNumber *representedValue = [item.representedObject isKindOfClass:[NSNumber class]] ? item.representedObject : nil;
        if (representedValue.integerValue == clampedValue) {
            [self.overlayMaxVisibleLinesPopup selectItem:item];
            return;
        }
    }

    [self.overlayMaxVisibleLinesPopup selectItemAtIndex:0];
}

- (void)updateOverlayLineLimitControlsEnabled {
    self.overlayMaxVisibleLinesPopup.enabled = self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
}

- (NSView *)sliderControlWithSlider:(NSSlider *)slider valueLabel:(NSTextField *)valueLabel width:(CGFloat)width {
    CGFloat spacing = 10.0;
    CGFloat height = MAX(slider.frame.size.height, valueLabel.frame.size.height);
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

    slider.frame = NSMakeRect(0,
                              floor((height - slider.frame.size.height) / 2.0),
                              width - valueLabel.frame.size.width - spacing,
                              slider.frame.size.height);
    valueLabel.frame = NSMakeRect(CGRectGetMaxX(slider.frame) + spacing,
                                  floor((height - valueLabel.frame.size.height) / 2.0),
                                  valueLabel.frame.size.width,
                                  valueLabel.frame.size.height);
    [container addSubview:slider];
    [container addSubview:valueLabel];
    return container;
}

- (NSTextField *)descriptionLabel:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (CGFloat)fittingHeightForWrappingLabel:(NSTextField *)label width:(CGFloat)width {
    NSTextFieldCell *cell = (NSTextFieldCell *)label.cell;
    NSSize measuredSize = [cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)];
    return ceil(MAX(18.0, measuredSize.height));
}

- (NSTextField *)addSettingsDescriptionText:(NSString *)text
                                     toPane:(NSView *)pane
                                      topY:(CGFloat)topY
                                         x:(CGFloat)x
                                     width:(CGFloat)width {
    NSTextField *label = [self descriptionLabel:text];
    CGFloat height = [self fittingHeightForWrappingLabel:label width:width];
    label.frame = NSMakeRect(x, floor(topY - height), width, height);
    [pane addSubview:label];
    return label;
}

- (NSTextField *)settingsRowLabelWithString:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    label.textColor = NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSSwitch *)settingsSwitchWithAction:(SEL)action {
    return [self settingsSwitchWithAction:action controlSize:NSControlSizeRegular];
}

- (NSSwitch *)settingsSwitchWithAction:(SEL)action controlSize:(NSControlSize)controlSize {
    NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    toggle.controlSize = controlSize;
    toggle.target = self;
    toggle.action = action;
    [toggle sizeToFit];
    return toggle;
}

- (void)enumerateSubviewsRecursivelyInView:(NSView *)view usingBlock:(void (^)(NSView *subview))block {
    for (NSView *subview in view.subviews) {
        block(subview);
        [self enumerateSubviewsRecursivelyInView:subview usingBlock:block];
    }
}

- (void)setHidden:(BOOL)hidden forViewsMatchingTags:(NSIndexSet *)tags inView:(NSView *)view {
    [self enumerateSubviewsRecursivelyInView:view usingBlock:^(NSView *subview) {
        if ([tags containsIndex:(NSUInteger)subview.tag]) {
            subview.hidden = hidden;
        }
    }];
}

- (void)setHidden:(BOOL)hidden forViewsWithTagInRange:(NSRange)range inView:(NSView *)view {
    [self enumerateSubviewsRecursivelyInView:view usingBlock:^(NSView *subview) {
        if (NSLocationInRange((NSUInteger)subview.tag, range)) {
            subview.hidden = hidden;
        }
    }];
}

- (void)applySettingsPaneBackgroundToView:(NSView *)pane {
    SPPaneBackgroundView *bg = [[SPPaneBackgroundView alloc] initWithFrame:pane.bounds];
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [pane addSubview:bg positioned:NSWindowBelow relativeTo:nil];
}

- (NSTextField *)sectionTitleLabel:(NSString *)title frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:title.uppercaseString];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

- (NSView *)surfaceCardViewWithFrame:(NSRect)frame {
    SPCardView *card = [[SPCardView alloc] initWithFrame:frame];
    return card;
}

- (NSView *)settingsToggleCardWithFrame:(NSRect)frame title:(NSString *)title toggle:(NSSwitch *)toggle {
    NSView *card = [self surfaceCardViewWithFrame:frame];
    CGFloat toggleW = toggle.frame.size.width;
    CGFloat toggleH = toggle.frame.size.height;
    if (toggleW <= 0.0 || toggleH <= 0.0) {
        [toggle sizeToFit];
        toggleW = toggle.frame.size.width;
        toggleH = toggle.frame.size.height;
    }

    NSTextField *label = [self settingsRowLabelWithString:title];
    label.frame = NSMakeRect(14.0,
                             floor((frame.size.height - 20.0) / 2.0),
                             MAX(80.0, frame.size.width - toggleW - 40.0),
                             20.0);
    [card addSubview:label];

    toggle.frame = NSMakeRect(frame.size.width - 14.0 - toggleW,
                              floor((frame.size.height - toggleH) / 2.0),
                              toggleW,
                              toggleH);
    [card addSubview:toggle];

    return card;
}

- (NSSegmentedControl *)templateActionSegmentedControlWithSymbols:(NSArray<NSString *> *)symbolNames
                                                         toolTips:(NSArray<NSString *> *)toolTips
                                                           action:(SEL)action {
    NSSegmentedControl *control = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 50, 24)];
    control.segmentCount = symbolNames.count;
    control.segmentStyle = NSSegmentStyleTexturedRounded;
    control.trackingMode = NSSegmentSwitchTrackingMomentary;
    control.controlSize = NSControlSizeSmall;
    control.target = self;
    control.action = action;

    for (NSInteger idx = 0; idx < (NSInteger)symbolNames.count; idx++) {
        NSString *symbolName = symbolNames[idx];
        NSString *toolTip = idx < (NSInteger)toolTips.count ? toolTips[idx] : @"";
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:toolTip];
        image.size = NSMakeSize(12, 12);
        [control setImage:image forSegment:idx];
        [control setWidth:24 forSegment:idx];
        [[control cell] setToolTip:toolTip forSegment:idx];
    }

    return control;
}

// ─── Card Layout Helpers ───────────────────────────────────────────

- (NSView *)cardWithTitle:(NSString *)title rows:(NSArray<NSView *> *)rows width:(CGFloat)width {
    CGFloat rowHeight = 44.0;
    CGFloat cardPad = 16.0;

    CGFloat cardHeight = rows.count * rowHeight;
    CGFloat titleHeight = title.length > 0 ? 28.0 : 0.0;
    CGFloat totalHeight = titleHeight + cardHeight;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

    if (title.length > 0) {
        NSTextField *titleLabel = [NSTextField labelWithString:title.uppercaseString];
        titleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        titleLabel.textColor = NSColor.secondaryLabelColor;
        titleLabel.frame = NSMakeRect(cardPad, cardHeight, width - 2 * cardPad, 20);
        [container addSubview:titleLabel];
    }

    NSView *card = [self surfaceCardViewWithFrame:NSMakeRect(0, 0, width, cardHeight)];
    [container addSubview:card];

    for (NSUInteger i = 0; i < rows.count; i++) {
        NSView *row = rows[i];
        CGFloat rowY = cardHeight - (i + 1) * rowHeight;
        row.frame = NSMakeRect(0, rowY, width, rowHeight);
        [card addSubview:row];

        if (i < rows.count - 1) {
            NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(cardPad, rowY, width - cardPad, 1)];
            sep.boxType = NSBoxSeparator;
            [card addSubview:sep];
        }
    }

    return container;
}

- (NSView *)cardRowWithLabel:(NSString *)label control:(NSView *)control {
    CGFloat rowHeight = 44.0;
    CGFloat pad = 16.0;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, rowHeight)];

    NSTextField *lbl = [NSTextField labelWithString:label];
    lbl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    lbl.textColor = NSColor.labelColor;
    lbl.frame = NSMakeRect(pad, (rowHeight - 20) / 2.0, 200, 20);
    [row addSubview:lbl];

    CGFloat controlW = control.frame.size.width;
    CGFloat controlH = control.frame.size.height;
    // Will be repositioned when parent sets the row's frame width
    control.frame = NSMakeRect(0, (rowHeight - controlH) / 2.0, controlW, controlH);
    control.autoresizingMask = NSViewMinXMargin;
    [row addSubview:control];

    return row;
}

- (void)layoutCardRowControls:(NSView *)card width:(CGFloat)width {
    CGFloat pad = 16.0;
    for (NSView *row in card.subviews) {
        for (NSView *sub in row.subviews) {
            if (sub.autoresizingMask & NSViewMinXMargin) {
                CGFloat controlW = sub.frame.size.width;
                CGFloat controlH = sub.frame.size.height;
                sub.frame = NSMakeRect(width - pad - controlW,
                                       (row.frame.size.height - controlH) / 2.0,
                                       controlW, controlH);
            }
        }
    }
}

- (NSButton *)eyeButtonWithFrame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bezelStyle = NSBezelStyleInline;
    button.bordered = NO;
    button.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
    button.imageScaling = NSImageScaleProportionallyUpOrDown;
    button.target = self;
    button.action = action;
    button.tag = 0; // 0 = hidden, 1 = visible
    return button;
}

- (void)toggleAsrAccessKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        // Show plain text
        self.asrAccessKeyField.stringValue = self.asrAccessKeySecureField.stringValue;
        self.asrAccessKeySecureField.hidden = YES;
        self.asrAccessKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        // Show secure
        self.asrAccessKeySecureField.stringValue = self.asrAccessKeyField.stringValue;
        self.asrAccessKeyField.hidden = YES;
        self.asrAccessKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)toggleQwenApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        // Show plain text
        self.asrQwenApiKeyField.stringValue = self.asrQwenApiKeySecureField.stringValue;
        self.asrQwenApiKeySecureField.hidden = YES;
        self.asrQwenApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        // Show secure
        self.asrQwenApiKeySecureField.stringValue = self.asrQwenApiKeyField.stringValue;
        self.asrQwenApiKeyField.hidden = YES;
        self.asrQwenApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)asrProviderChanged:(NSPopUpButton *)sender {
    NSString *selectedProvider = sender.selectedItem.representedObject ?: @"doubaoime";
    BOOL isDoubaoIme = [selectedProvider isEqualToString:@"doubaoime"];
    BOOL isDoubao = [selectedProvider isEqualToString:@"doubao"];
    BOOL isQwen = [selectedProvider isEqualToString:@"qwen"];
    BOOL isAppleSpeech = [selectedProvider isEqualToString:@"apple-speech"];
    BOOL isModelBasedLocal = !isDoubaoIme && !isDoubao && !isQwen && !isAppleSpeech;

    // Show/hide Doubao fields
    [self setHidden:!isDoubao
 forViewsMatchingTags:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1001, 2)]
             inView:self.currentPaneView];
    self.asrAppKeyField.hidden = !isDoubao;
    self.asrAccessKeyField.hidden = YES; // Always start hidden (secure mode)
    self.asrAccessKeySecureField.hidden = !isDoubao;
    self.asrAccessKeyToggle.hidden = !isDoubao;

    // Show/hide Qwen fields
    [self setHidden:!isQwen
 forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1003]
             inView:self.currentPaneView];
    self.asrQwenApiKeyField.hidden = YES; // Always start hidden (secure mode)
    self.asrQwenApiKeySecureField.hidden = !isQwen;
    self.asrQwenApiKeyToggle.hidden = !isQwen;

    // Show/hide Apple Speech locale popup and asset status
    self.appleSpeechLocalePopup.hidden = !isAppleSpeech;
    [self setHidden:!isAppleSpeech
 forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1005]
             inView:self.currentPaneView];

    // Show/hide local model popup, status, and download button
    self.localModelPopup.hidden = !isModelBasedLocal;
    if (!isModelBasedLocal && !isAppleSpeech) {
        self.modelStatusLabel.hidden = YES;
        self.modelDownloadButton.hidden = YES;
        self.modelDeleteButton.hidden = YES;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
    } else if (isAppleSpeech) {
        // Reuse model status row for Apple Speech asset status
        self.modelStatusLabel.hidden = NO;
        self.modelDownloadButton.hidden = NO;
        self.modelDeleteButton.hidden = NO;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
        [self updateAppleSpeechAssetStatus];
    } else {
        self.modelStatusLabel.hidden = NO;
        self.modelDownloadButton.hidden = NO;
        self.modelDeleteButton.hidden = NO;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
        [self updateModelStatusLabel];
    }
    [self setHidden:!isModelBasedLocal
 forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1004]
             inView:self.currentPaneView];
    if (isModelBasedLocal) {
        [self populateLocalModelPopup:selectedProvider mode:@"asr"];
        [self updateModelStatusLabel];
    }

    // Hide test button for local providers (no remote connection to test)
    BOOL isLocal = !isDoubaoIme && !isDoubao && !isQwen;
    self.asrTestButton.hidden = isLocal;
    self.asrTestResultLabel.hidden = isLocal;

    // Clear test result when switching provider
    self.asrTestResultLabel.stringValue = @"";
    self.asrTestButton.enabled = YES;
}

- (void)localModelChanged:(id)sender {
    [self updateModelStatusLabel];
}

- (void)updateModelStatusLabel {
    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) {
        self.modelStatusLabel.stringValue = @"";
        self.modelDownloadButton.enabled = NO;
        self.modelDeleteButton.enabled = NO;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
        return;
    }

    // If selected model is currently downloading, show progress UI
    if ([self.downloadingModels containsObject:modelPath]) {
        self.modelStatusLabel.stringValue = @"Downloading";
        self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                     accessibilityDescription:@"Stop"];
        self.modelDownloadButton.enabled = YES;
        self.modelDeleteButton.enabled = NO;
        self.modelProgressBar.hidden = NO;
        self.modelProgressSizeLabel.hidden = NO;
        return;
    }

    // 1. Cache-only lookup (~1ms)
    NSInteger cachedStatus = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyCacheOnly];
    if (cachedStatus == 2) {
        [self applyModelStatus:cachedStatus];
        return;
    }

    // 2. Cache miss or incomplete — show "Verifying…" and dispatch async
    [self applyModelStatus:(cachedStatus > 0 ? cachedStatus : 1) verifying:YES];
    self.pendingVerificationPath = modelPath;

    dispatch_async(_verifyQueue, ^{
        NSInteger verified = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyNormal];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.pendingVerificationPath isEqualToString:modelPath]) {
                self.pendingVerificationPath = nil;
                [self applyModelStatus:verified];
            }
        });
    });
}

- (void)applyModelStatus:(NSInteger)status {
    [self applyModelStatus:status verifying:NO];
}

- (void)applyModelStatus:(NSInteger)status verifying:(BOOL)verifying {
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                 accessibilityDescription:@"Download"];
    switch (status) {
        case 2:
            self.modelStatusLabel.stringValue = verifying ? @"● Verifying…" : @"● Installed";
            self.modelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemGreenColor];
            self.modelDownloadButton.enabled = NO;
            self.modelDeleteButton.enabled = YES;
            break;
        case 1:
            self.modelStatusLabel.stringValue = verifying ? @"◐ Verifying…" : @"◐ Incomplete";
            self.modelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemOrangeColor];
            self.modelDownloadButton.enabled = YES;
            self.modelDeleteButton.enabled = YES;
            break;
        default:
            self.modelStatusLabel.stringValue = @"○ Not installed";
            self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
            self.modelDownloadButton.enabled = YES;
            self.modelDeleteButton.enabled = NO;
            break;
    }
}

- (void)downloadSelectedModel:(id)sender {
    // Dispatch to Apple Speech asset download if that provider is selected
    NSString *selectedProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubaoime";
    if ([selectedProvider isEqualToString:@"apple-speech"]) {
        [self downloadAppleSpeechAsset];
        return;
    }

    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    // If this model is downloading, cancel it
    if ([self.downloadingModels containsObject:modelPath]) {
        [self.rustBridge cancelDownload:modelPath];
        return;
    }

    if (!self.downloadingModels) {
        self.downloadingModels = [NSMutableSet new];
    }
    [self.downloadingModels addObject:modelPath];

    // Switch to stop icon and show progress bar
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                 accessibilityDescription:@"Stop"];
    self.modelDownloadButton.hidden = NO;
    self.modelStatusLabel.stringValue = @"Downloading...";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelProgressBar.hidden = NO;
    self.modelProgressBar.doubleValue = 0;
    self.modelProgressSizeLabel.hidden = NO;
    self.modelProgressSizeLabel.stringValue = @"";

    // Get total size from scan_models data
    __block uint64_t totalBytesAllFiles = 0;
    for (NSDictionary *m in [self.rustBridge scanModels]) {
        if ([m[@"path"] isEqualToString:modelPath]) {
            totalBytesAllFiles = [m[@"total_size"] unsignedLongLongValue];
            break;
        }
    }
    __block NSMutableDictionary<NSNumber *, NSNumber *> *fileDownloaded = [NSMutableDictionary new];

    __weak typeof(self) weakSelf = self;
    [self.rustBridge downloadModel:modelPath
        progress:^(NSUInteger fileIndex, NSUInteger fileCount,
                   uint64_t downloaded, uint64_t total, NSString *filename) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            // Only update UI if this model is still selected
            NSString *selected = strongSelf.localModelPopup.selectedItem.representedObject;
            if (![modelPath isEqualToString:selected]) return;

            fileDownloaded[@(fileIndex)] = @(downloaded);

            uint64_t totalDownloaded = 0;
            for (NSNumber *v in fileDownloaded.allValues) totalDownloaded += v.unsignedLongLongValue;

            double pct = (totalBytesAllFiles > 0)
                ? (double)totalDownloaded / (double)totalBytesAllFiles * 100.0 : 0;
            strongSelf.modelProgressBar.doubleValue = pct;
            strongSelf.modelStatusLabel.stringValue = @"Downloading";
            strongSelf.modelProgressSizeLabel.stringValue =
                [NSString stringWithFormat:@"%.1f / %.1f MB",
                    (double)totalDownloaded / 1048576.0,
                    (double)totalBytesAllFiles / 1048576.0];
        }
        completion:^(BOOL success, NSString *message) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.downloadingModels removeObject:modelPath];
            [strongSelf updateModelStatusLabel];
        }];
}

- (void)deleteSelectedModel:(id)sender {
    // Dispatch to Apple Speech asset release if that provider is selected
    NSString *selectedProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubaoime";
    if ([selectedProvider isEqualToString:@"apple-speech"]) {
        [self releaseAppleSpeechAsset];
        return;
    }

    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove Model Files?";
    alert.informativeText = @"Downloaded model files will be deleted. The model can be re-downloaded later.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.rustBridge removeModelFiles:modelPath];
        [self updateModelStatusLabel];
    }
}

// MARK: - Apple Speech Asset Management

- (void)populateAppleSpeechLocalePopup {
    [self.appleSpeechLocalePopup removeAllItems];

    uint32_t blobLen = 0;
    uint8_t *blob = koe_apple_speech_supported_locales(&blobLen);
    if (blob && blobLen > 0) {
        // Parse "id\0displayName\0\0id\0displayName\0\0..." blob
        NSData *data = [NSData dataWithBytesNoCopy:blob length:blobLen freeWhenDone:YES];
        const uint8_t *bytes = data.bytes;
        NSUInteger pos = 0;
        while (pos < blobLen) {
            // Read identifier (until first \0)
            NSUInteger idStart = pos;
            while (pos < blobLen && bytes[pos] != 0) pos++;
            if (pos >= blobLen) break;
            NSString *identifier = [[NSString alloc] initWithBytes:bytes + idStart
                                                            length:pos - idStart
                                                          encoding:NSUTF8StringEncoding];
            pos++; // skip \0

            // Read display name (until next \0)
            NSUInteger nameStart = pos;
            while (pos < blobLen && bytes[pos] != 0) pos++;
            NSString *displayName = [[NSString alloc] initWithBytes:bytes + nameStart
                                                             length:pos - nameStart
                                                           encoding:NSUTF8StringEncoding];
            pos++; // skip \0

            // Skip trailing \0 (double-null separator)
            if (pos < blobLen && bytes[pos] == 0) pos++;

            if (identifier && displayName) {
                [self.appleSpeechLocalePopup addItemWithTitle:displayName];
                [self.appleSpeechLocalePopup lastItem].representedObject = identifier;
            }
        }
    } else {
        // Fallback if API unavailable
        [self.appleSpeechLocalePopup addItemWithTitle:@"No languages available"];
        self.appleSpeechLocalePopup.enabled = NO;
    }
}

- (void)updateAppleSpeechAssetStatus {
    NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
    int32_t status = koe_apple_speech_asset_status(locale.UTF8String);

    switch (status) {
        case 3: { // installed
            self.modelStatusLabel.stringValue = @"● Installed";
            self.modelStatusLabel.textColor = [NSColor systemGreenColor];
            self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                        accessibilityDescription:@"Download"];
            self.modelDownloadButton.enabled = NO;
            self.modelDeleteButton.enabled = YES;
            break;
        }
        case 2: // downloading
            self.modelStatusLabel.stringValue = @"◐ Downloading…";
            self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
            self.modelDownloadButton.enabled = NO;
            self.modelDeleteButton.enabled = NO;
            break;
        case 1: // supported (downloadable)
            self.modelStatusLabel.stringValue = @"○ Not installed";
            self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
            self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                        accessibilityDescription:@"Download"];
            self.modelDownloadButton.enabled = YES;
            self.modelDeleteButton.enabled = NO;
            break;
        default: // unsupported
            self.modelStatusLabel.stringValue = @"✕ Not supported for this language";
            self.modelStatusLabel.textColor = [NSColor systemRedColor];
            self.modelDownloadButton.enabled = NO;
            self.modelDeleteButton.enabled = NO;
            break;
    }
}

static void appleSpeechInstallCallback(void *ctx, int32_t eventType, const char *text) {
    SPSetupWizardWindowController *controller = (__bridge SPSetupWizardWindowController *)ctx;
    NSString *textStr = text ? [NSString stringWithUTF8String:text] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (eventType) {
            case 0: // progress
                controller.modelStatusLabel.stringValue = textStr ?: @"Downloading…";
                controller.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
                break;
            case 1: // completed
                [controller updateAppleSpeechAssetStatus];
                break;
            case 2: // error
                controller.modelStatusLabel.stringValue = textStr ?: @"Download failed";
                controller.modelStatusLabel.textColor = [NSColor systemRedColor];
                controller.modelDownloadButton.enabled = YES;
                break;
        }
    });
}

- (void)appleSpeechLocaleChanged:(id)sender {
    [self updateAppleSpeechAssetStatus];
}

- (void)releaseAppleSpeechAsset {
    NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Release Speech Assets?";
    alert.informativeText = @"The system may reclaim storage for this language's speech model. You can re-download it later.";
    [alert addButtonWithTitle:@"Release"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        koe_apple_speech_release_asset(locale.UTF8String);
        [self updateAppleSpeechAssetStatus];
    }
}

- (void)downloadAppleSpeechAsset {
    NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
    self.modelStatusLabel.stringValue = @"Downloading…";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelDownloadButton.enabled = NO;
    koe_apple_speech_install_asset(locale.UTF8String, appleSpeechInstallCallback, (__bridge void *)self);
}

- (void)populateLocalModelPopup:(NSString *)provider {
    [self populateLocalModelPopup:provider mode:nil];
}

- (void)populateLocalModelPopup:(NSString *)provider mode:(NSString *)mode {
    [self.localModelPopup removeAllItems];

    NSArray<NSDictionary *> *models = [self.rustBridge scanModels];
    for (NSDictionary *model in models) {
        if (![model[@"provider"] isEqualToString:provider]) continue;
        // Filter by mode: treat empty/missing mode as "asr" for backward compat
        if (mode) {
            NSString *modelMode = model[@"mode"];
            if (!modelMode || modelMode.length == 0) modelMode = @"asr";
            if (![modelMode isEqualToString:mode]) continue;
        }

        NSString *path = model[@"path"];
        NSString *title = model[@"description"] ?: path;

        [self.localModelPopup addItemWithTitle:title];
        [self.localModelPopup lastItem].representedObject = path;
    }

    if (self.localModelPopup.numberOfItems == 0) {
        [self.localModelPopup addItemWithTitle:@"No models found"];
        self.localModelPopup.enabled = NO;
    } else {
        self.localModelPopup.enabled = YES;
    }
}

- (void)toggleLlmApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        self.llmApiKeyField.stringValue = self.llmApiKeySecureField.stringValue;
        self.llmApiKeySecureField.hidden = YES;
        self.llmApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        self.llmApiKeySecureField.stringValue = self.llmApiKeyField.stringValue;
        self.llmApiKeyField.hidden = YES;
        self.llmApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (NSMutableDictionary *)mutableLlmProfileFromDictionary:(NSDictionary *)profile {
    NSMutableDictionary *copy = [profile mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *mlx = copy[@"mlx"];
    copy[@"mlx"] = [mlx isKindOfClass:[NSDictionary class]] ? [mlx mutableCopy] : [@{@"model": @"mlx/Qwen3-0.6B-4bit"} mutableCopy];
    NSString *chatPath = [copy[@"chat_completions_path"] isKindOfClass:[NSString class]] ? copy[@"chat_completions_path"] : @"";
    if (chatPath.length == 0) {
        copy[@"chat_completions_path"] = kDefaultLlmChatCompletionsPath;
    }
    return copy;
}

- (NSMutableDictionary *)defaultOpenAILlmProfileWithName:(NSString *)name {
    return [@{
        @"name": name ?: @"OpenAI Compatible",
        @"provider": @"openai",
        @"base_url": @"https://api.openai.com/v1",
        @"api_key": @"",
        @"model": @"gpt-5.4-nano",
        @"chat_completions_path": kDefaultLlmChatCompletionsPath,
        @"max_token_parameter": @"max_completion_tokens",
        @"no_reasoning_control": @"reasoning_effort",
        @"mlx": @{@"model": @"mlx/Qwen3-0.6B-4bit"},
    } mutableCopy];
}

- (NSMutableDictionary *)defaultApfelLlmProfile {
    return [@{
        @"name": @"APFEL",
        @"provider": @"apfel",
        @"base_url": @"http://127.0.0.1:11434/v1",
        @"api_key": @"",
        @"model": @"apple-foundationmodel",
        @"chat_completions_path": kDefaultLlmChatCompletionsPath,
        @"max_token_parameter": @"max_tokens",
        @"no_reasoning_control": @"none",
        @"mlx": @{@"model": @"mlx/Qwen3-0.6B-4bit"},
    } mutableCopy];
}

- (NSMutableDictionary *)defaultMlxLlmProfileWithName:(NSString *)name {
    return [@{
        @"name": name ?: @"MLX (Apple Silicon)",
        @"provider": @"mlx",
        @"base_url": @"",
        @"api_key": @"",
        @"model": @"",
        @"chat_completions_path": kDefaultLlmChatCompletionsPath,
        @"max_token_parameter": @"max_completion_tokens",
        @"no_reasoning_control": @"none",
        @"mlx": @{@"model": @"mlx/Qwen3-0.6B-4bit"},
    } mutableCopy];
}

- (NSString *)prettyNameForLlmProvider:(NSString *)provider {
    if ([provider isEqualToString:@"apfel"]) return @"APFEL";
    if ([provider isEqualToString:@"mlx"]) return @"MLX (Apple Silicon)";
    return @"OpenAI Compatible";
}

- (void)loadLlmProfilesFromCore {
    char *raw = sp_llm_profiles_json();
    NSString *jsonStr = raw ? [NSString stringWithUTF8String:raw] : @"";
    if (raw) sp_core_free_string(raw);

    NSDictionary *payload = nil;
    if (jsonStr.length > 0) {
        payload = [NSJSONSerialization JSONObjectWithData:[jsonStr dataUsingEncoding:NSUTF8StringEncoding]
                                                  options:0
                                                    error:nil];
    }

    self.llmProfiles = [NSMutableDictionary dictionary];
    NSDictionary *profiles = [payload[@"profiles"] isKindOfClass:[NSDictionary class]] ? payload[@"profiles"] : nil;
    for (NSString *profileId in profiles) {
        NSDictionary *profile = profiles[profileId];
        if ([profile isKindOfClass:[NSDictionary class]]) {
            self.llmProfiles[profileId] = [self mutableLlmProfileFromDictionary:profile];
        }
    }

    if (self.llmProfiles.count == 0) {
        self.llmProfiles[@"openai"] = [self defaultOpenAILlmProfileWithName:@"OpenAI Compatible"];
        self.llmProfiles[@"apfel"] = [self defaultApfelLlmProfile];
        self.llmProfiles[@"mlx"] = [self defaultMlxLlmProfileWithName:@"MLX (Apple Silicon)"];
    }

    NSString *activeProfile = [payload[@"active_profile"] isKindOfClass:[NSString class]] ? payload[@"active_profile"] : @"openai";
    self.activeLlmProfileId = self.llmProfiles[activeProfile] ? activeProfile : self.llmProfiles.allKeys.firstObject;
    [self reloadLlmProfileTable];
    [self applyActiveLlmProfileToFields];
}

- (void)reloadLlmProfileTable {
    self.llmProfileOrder = [[self.llmProfiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] mutableCopy];
    BOOL previousSuppress = self.suppressLlmProfileSelection;
    self.suppressLlmProfileSelection = YES;
    [self.llmProfileTableView reloadData];
    NSInteger activeRow = [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
    if (activeRow != NSNotFound && activeRow < (NSInteger)self.llmProfileOrder.count) {
        [self.llmProfileTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)activeRow]
                              byExtendingSelection:NO];
    }
    self.suppressLlmProfileSelection = previousSuppress;
}

- (NSMutableDictionary *)activeLlmProfile {
    if (!self.activeLlmProfileId) return nil;
    return self.llmProfiles[self.activeLlmProfileId];
}

- (void)syncActiveLlmProfileFromFields {
    NSMutableDictionary *profile = [self activeLlmProfile];
    if (!profile) return;

    // Provider is LOCKED at creation — read it from the profile dict, not UI.
    NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]] ? profile[@"provider"] : @"openai";
    NSString *name = [self.llmProfileNameField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length > 0) profile[@"name"] = name;
    profile[@"base_url"] = self.llmBaseUrlField.stringValue ?: @"";
    NSString *apiKey = self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue;
    profile[@"api_key"] = apiKey ?: @"";
    profile[@"model"] = self.llmModelField.stringValue ?: @"";
    NSString *chatPath = [[self.llmChatCompletionsPathField.stringValue ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    profile[@"chat_completions_path"] = (chatPath.length > 0) ? chatPath : kDefaultLlmChatCompletionsPath;
    profile[@"max_token_parameter"] = self.maxTokenParamPopup.selectedItem.representedObject ?: @"max_completion_tokens";
    if (!profile[@"no_reasoning_control"]) {
        BOOL usesReasoningEffort = [provider isEqualToString:@"openai"];
        profile[@"no_reasoning_control"] = usesReasoningEffort ? @"reasoning_effort" : @"none";
    }

    if ([provider isEqualToString:@"mlx"]) {
        NSMutableDictionary *mlx = [profile[@"mlx"] isKindOfClass:[NSMutableDictionary class]]
            ? profile[@"mlx"] : [@{} mutableCopy];
        NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
        if (modelPath) mlx[@"model"] = modelPath;
        profile[@"mlx"] = mlx;
    }
}

- (void)applyActiveLlmProfileToFields {
    NSDictionary *profile = [self activeLlmProfile];
    if (!profile) return;

    NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]] ? profile[@"provider"] : @"openai";
    NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] ? profile[@"name"] : @"";
    self.llmProfileNameField.stringValue = name;
    self.llmProfileTypeLabel.stringValue = [self prettyNameForLlmProvider:provider];

    self.llmBaseUrlField.stringValue = [profile[@"base_url"] isKindOfClass:[NSString class]] ? profile[@"base_url"] : @"";
    NSString *apiKey = [profile[@"api_key"] isKindOfClass:[NSString class]] ? profile[@"api_key"] : @"";
    self.llmApiKeySecureField.stringValue = apiKey;
    self.llmApiKeyField.stringValue = apiKey;
    self.llmApiKeySecureField.hidden = NO;
    self.llmApiKeyField.hidden = YES;
    self.llmApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
    self.llmApiKeyToggle.tag = 0;
    self.llmModelField.stringValue = [profile[@"model"] isKindOfClass:[NSString class]] ? profile[@"model"] : @"";
    NSString *chatPath = [profile[@"chat_completions_path"] isKindOfClass:[NSString class]]
        ? profile[@"chat_completions_path"] : kDefaultLlmChatCompletionsPath;
    self.llmChatCompletionsPathField.stringValue = chatPath.length > 0 ? chatPath : kDefaultLlmChatCompletionsPath;

    NSString *maxTokenParam = [profile[@"max_token_parameter"] isKindOfClass:[NSString class]]
        ? profile[@"max_token_parameter"] : @"max_completion_tokens";
    for (NSInteger i = 0; i < self.maxTokenParamPopup.numberOfItems; i++) {
        if ([[self.maxTokenParamPopup itemAtIndex:i].representedObject isEqualToString:maxTokenParam]) {
            [self.maxTokenParamPopup selectItemAtIndex:i];
            break;
        }
    }

    if ([provider isEqualToString:@"mlx"]) {
        [self populateLlmLocalModelPopup];
        NSString *mlxModel = [profile[@"mlx"] isKindOfClass:[NSDictionary class]] ? profile[@"mlx"][@"model"] : nil;
        if (mlxModel.length > 0) {
            for (NSInteger i = 0; i < self.llmLocalModelPopup.numberOfItems; i++) {
                if ([[self.llmLocalModelPopup itemAtIndex:i].representedObject isEqualToString:mlxModel]) {
                    [self.llmLocalModelPopup selectItemAtIndex:i];
                    break;
                }
            }
        }
        [self updateLlmModelStatusLabel];
    } else if (self.llmRemoteModelPickerExpanded) {
        [self refreshLlmRemoteModels:nil];
    }

    [self updateLlmFieldsEnabled];
}

- (NSString *)newLlmProfileIdWithPrefix:(NSString *)prefix {
    NSString *base = prefix ?: @"profile";
    if (!self.llmProfiles[base]) return base;
    NSInteger index = 2;
    while (self.llmProfiles[[NSString stringWithFormat:@"%@-%ld", base, (long)index]]) {
        index++;
    }
    return [NSString stringWithFormat:@"%@-%ld", base, (long)index];
}

- (void)llmProfileNameChanged:(id)sender {
    NSMutableDictionary *profile = [self activeLlmProfile];
    if (!profile) return;
    NSString *name = [self.llmProfileNameField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    profile[@"name"] = name.length > 0 ? name : profile[@"name"] ?: @"";
    NSInteger row = [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
    if (row != NSNotFound) {
        [self.llmProfileTableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                                            columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (void)showAddLlmProfileMenu:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *openaiItem = [[NSMenuItem alloc] initWithTitle:@"OpenAI Compatible"
                                                        action:@selector(addLlmProfileFromMenu:)
                                                 keyEquivalent:@""];
    openaiItem.target = self;
    openaiItem.representedObject = @"openai";
    [menu addItem:openaiItem];
    NSMenuItem *apfelItem = [[NSMenuItem alloc] initWithTitle:@"APFEL"
                                                       action:@selector(addLlmProfileFromMenu:)
                                                keyEquivalent:@""];
    apfelItem.target = self;
    apfelItem.representedObject = @"apfel";
    [menu addItem:apfelItem];
    NSMenuItem *mlxItem = [[NSMenuItem alloc] initWithTitle:@"MLX (Apple Silicon)"
                                                     action:@selector(addLlmProfileFromMenu:)
                                              keyEquivalent:@""];
    mlxItem.target = self;
    mlxItem.representedObject = @"mlx";
    [menu addItem:mlxItem];

    NSButton *button = (NSButton *)sender;
    NSPoint origin = NSMakePoint(0, NSHeight(button.bounds) + 2);
    [menu popUpMenuPositioningItem:nil atLocation:origin inView:button];
}

- (void)addLlmProfileFromMenu:(NSMenuItem *)item {
    NSString *type = item.representedObject;
    if (!type) return;
    [self syncActiveLlmProfileFromFields];

    NSString *prefix = [type isEqualToString:@"mlx"] ? @"mlx" : ([type isEqualToString:@"apfel"] ? @"apfel" : @"openai");
    NSString *profileId = [self newLlmProfileIdWithPrefix:prefix];
    NSMutableDictionary *profile = nil;
    if ([type isEqualToString:@"apfel"]) {
        profile = [self defaultApfelLlmProfile];
        profile[@"name"] = @"APFEL";
    } else if ([type isEqualToString:@"mlx"]) {
        profile = [self defaultMlxLlmProfileWithName:@"MLX (Apple Silicon)"];
    } else {
        profile = [self defaultOpenAILlmProfileWithName:@"OpenAI Compatible"];
    }
    self.llmProfiles[profileId] = profile;
    self.activeLlmProfileId = profileId;
    [self reloadLlmProfileTable];
    [self applyActiveLlmProfileToFields];
    self.llmTestResultLabel.stringValue = @"";
    [self updateLlmFieldsEnabled];
}

- (void)deleteLlmProfile:(id)sender {
    if (self.llmProfiles.count <= 1 || !self.activeLlmProfileId) return;
    NSString *oldId = self.activeLlmProfileId;
    [self.llmProfiles removeObjectForKey:oldId];
    self.activeLlmProfileId = [self.llmProfiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)].firstObject;
    [self reloadLlmProfileTable];
    [self applyActiveLlmProfileToFields];
    self.llmTestResultLabel.stringValue = @"";
    [self updateLlmFieldsEnabled];
}

- (NSDictionary *)runtimeLlmProfileForActiveProfile {
    [self syncActiveLlmProfileFromFields];
    NSMutableDictionary *profile = [[self activeLlmProfile] mutableCopy];
    if (!profile) return nil;
    profile[@"id"] = self.activeLlmProfileId ?: @"";
    return profile;
}

// ─── Load / Save ────────────────────────────────────────────────────

- (void)loadCurrentValues {
    [self loadValuesForPane:self.currentPaneIdentifier];
}

- (void)loadValuesForPane:(NSString *)identifier {
    NSString *dir = configDirPath();

    if ([identifier isEqualToString:kToolbarASR]) {
        NSString *provider = configGet(@"asr.provider");
        if (provider.length == 0) provider = @"doubaoime";
        for (NSInteger i = 0; i < self.asrProviderPopup.numberOfItems; i++) {
            if ([[self.asrProviderPopup itemAtIndex:i].representedObject isEqualToString:provider]) {
                [self.asrProviderPopup selectItemAtIndex:i];
                break;
            }
        }
        // Load Doubao fields
        self.asrAppKeyField.stringValue = configGet(@"asr.doubao.app_key");
        NSString *accessKey = configGet(@"asr.doubao.access_key");
        self.asrAccessKeySecureField.stringValue = accessKey;
        self.asrAccessKeyField.stringValue = accessKey;
        // Load Qwen fields
        NSString *qwenApiKey = configGet(@"asr.qwen.api_key");
        self.asrQwenApiKeySecureField.stringValue = qwenApiKey;
        self.asrQwenApiKeyField.stringValue = qwenApiKey;
        // Reset visibility based on selected provider
        [self asrProviderChanged:self.asrProviderPopup];
        // Select saved Apple Speech locale (always, so switching to apple-speech shows the right default)
        {
            NSString *locale = configGet(@"asr.apple-speech.locale");
            if (locale.length > 0) {
                // Try exact match first, then fall back to language-equivalent match
                NSInteger exactIdx = -1, equivIdx = -1;
                NSLocale *configLocale = [NSLocale localeWithLocaleIdentifier:locale];
                for (NSInteger i = 0; i < self.appleSpeechLocalePopup.numberOfItems; i++) {
                    NSString *itemId = [self.appleSpeechLocalePopup itemAtIndex:i].representedObject;
                    if ([itemId isEqualToString:locale]) {
                        exactIdx = i;
                        break;
                    }
                    if (equivIdx < 0) {
                        NSLocale *itemLocale = [NSLocale localeWithLocaleIdentifier:itemId];
                        if ([configLocale.languageCode isEqualToString:itemLocale.languageCode]
                            && [configLocale.countryCode isEqualToString:itemLocale.countryCode]) {
                            equivIdx = i;
                        }
                    }
                }
                NSInteger matchIdx = (exactIdx >= 0) ? exactIdx : equivIdx;
                if (matchIdx >= 0) {
                    [self.appleSpeechLocalePopup selectItemAtIndex:matchIdx];
                    [self updateAppleSpeechAssetStatus];
                }
            }
        }
        // Select current local model if applicable
        NSString *currentModel = nil;
        if ([provider isEqualToString:@"mlx"]) {
            currentModel = configGet(@"asr.mlx.model");
        } else if ([provider isEqualToString:@"sherpa-onnx"]) {
            currentModel = configGet(@"asr.sherpa-onnx.model");
        }
        if (currentModel.length > 0) {
            for (NSInteger i = 0; i < self.localModelPopup.numberOfItems; i++) {
                if ([[self.localModelPopup itemAtIndex:i].representedObject isEqualToString:currentModel]) {
                    [self.localModelPopup selectItemAtIndex:i];
                    break;
                }
            }
            [self updateModelStatusLabel];
        }
        // Clear test result when loading
        self.asrTestResultLabel.stringValue = @"";
        self.asrTestButton.enabled = YES;
    } else if ([identifier isEqualToString:kToolbarLLM]) {
        NSString *enabled = configGet(@"llm.enabled");
        self.llmEnabledCheckbox.state = ([enabled isEqualToString:@"false"]) ? NSControlStateValueOff : NSControlStateValueOn;

        [self loadLlmProfilesFromCore];
        self.llmTestResultLabel.stringValue = @"";
        [self updateLlmFieldsEnabled];
    } else if ([identifier isEqualToString:kToolbarOverlay]) {
        NSString *fontFamilyRaw = configGet(@"overlay.font_family");
        NSString *fontSizeRaw = configGet(@"overlay.font_size");
        NSString *bottomMarginRaw = configGet(@"overlay.bottom_margin");
        NSString *limitVisibleLinesRaw = configGet(@"overlay.limit_visible_lines");
        NSString *maxVisibleLinesRaw = configGet(@"overlay.max_visible_lines");
        NSString *fontFamily = fontFamilyRaw.length > 0 ? normalizedOverlayFontFamilyValue(fontFamilyRaw) : kOverlayFontFamilyDefault;
        NSInteger fontSize = fontSizeRaw.length > 0 ? clampedOverlayFontSizeValue(fontSizeRaw.integerValue) : kOverlayFontSizeDefault;
        NSInteger bottomMargin = bottomMarginRaw.length > 0 ? clampedOverlayBottomMarginValue(bottomMarginRaw.integerValue) : kOverlayBottomMarginDefault;
        BOOL limitVisibleLines = overlayLimitVisibleLinesEnabledValue(limitVisibleLinesRaw);
        NSInteger maxVisibleLines = maxVisibleLinesRaw.length > 0 ? clampedOverlayMaxVisibleLinesValue(maxVisibleLinesRaw.integerValue) : kOverlayMaxVisibleLinesDefault;

        [self selectOverlayFontFamilyValue:fontFamily];
        self.overlayFontSizeSlider.integerValue = fontSize;
        self.overlayBottomMarginSlider.integerValue = bottomMargin;
        self.overlayLimitVisibleLinesSwitch.state = limitVisibleLines ? NSControlStateValueOn : NSControlStateValueOff;
        [self selectOverlayMaxVisibleLinesValue:maxVisibleLines];
        [self syncOverlayPreviewFromControls];
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        NSString *triggerKeyRaw = configGet(@"hotkey.trigger_key");
        NSString *triggerKey = normalizedHotkeyValue(triggerKeyRaw);

        [self selectHotkeyValue:triggerKey inPopup:self.hotkeyPopup];

        // Load trigger mode
        NSString *triggerMode = configGet(@"hotkey.trigger_mode");
        if ([triggerMode isEqualToString:@"toggle"]) {
            [self.triggerModePopup selectItemAtIndex:1];
        } else {
            [self.triggerModePopup selectItemAtIndex:0];
        }

        NSString *startSound = configGet(@"feedback.start_sound");
        NSString *stopSound = configGet(@"feedback.stop_sound");
        NSString *errorSound = configGet(@"feedback.error_sound");
        self.startSoundCheckbox.state = [startSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
        self.stopSoundCheckbox.state = [stopSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
        self.errorSoundCheckbox.state = [errorSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        NSString *dictContent = [NSString stringWithContentsOfFile:dictPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.dictionaryTextView setString:dictContent];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        NSString *promptContent = [NSString stringWithContentsOfFile:promptPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.systemPromptTextView setString:promptContent];
    } else if ([identifier isEqualToString:kToolbarTemplates]) {
        NSString *templatesEnabled = configGet(@"llm.prompt_templates_enabled");
        self.templatesEnabledSwitch.state = [templatesEnabled isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;

        NSArray *templates = [self.rustBridge promptTemplates];
        self.templatesData = [NSMutableArray array];
        for (NSDictionary *t in templates) {
            NSMutableDictionary *templateData = [t mutableCopy] ?: [NSMutableDictionary dictionary];
            if (![templateData[@"enabled"] isKindOfClass:[NSNumber class]]) {
                templateData[@"enabled"] = @YES;
            }
            NSString *resolvedPrompt = [self resolvedPromptTextForTemplate:templateData];
            templateData[kTemplateEditablePromptKey] = resolvedPrompt ?: @"";
            templateData[kTemplateOriginalPromptKey] = resolvedPrompt ?: @"";
            [self.templatesData addObject:templateData];
        }
        [self reindexTemplateShortcuts];
        [self reloadTemplateTableSelectingRow:(self.templatesData.count > 0 ? 0 : -1)];
    }
}

- (void)saveConfig:(id)sender {
    [self endHotkeyRecording];

    // Warn if a local provider is selected but assets/models are not installed
    if (self.asrProviderPopup) {
        NSString *provider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubaoime";
        // Check Apple Speech asset status
        if ([provider isEqualToString:@"apple-speech"]) {
            NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
            int32_t assetStatus = koe_apple_speech_asset_status(locale.UTF8String);
            if (assetStatus != 3) { // not installed
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Speech Assets Not Installed";
                alert.informativeText = @"The speech recognition model for the selected language has not been downloaded yet. Saving will start downloading automatically.";
                [alert addButtonWithTitle:@"Save & Download"];
                [alert addButtonWithTitle:@"Cancel"];
                alert.alertStyle = NSAlertStyleWarning;
                if ([alert runModal] != NSAlertFirstButtonReturn) {
                    return;
                }
                // Trigger background download immediately
                [self downloadAppleSpeechAsset];
            }
        }
        // Check model-based local provider model status
        BOOL isModelBasedLocal = ![provider isEqualToString:@"doubaoime"]
            && ![provider isEqualToString:@"doubao"]
            && ![provider isEqualToString:@"qwen"]
            && ![provider isEqualToString:@"apple-speech"];
        if (isModelBasedLocal) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) {
                NSInteger status = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyCacheOnly];
                if (status != 2) { // not installed
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Model Not Installed";
                    alert.informativeText = @"The selected model has not been downloaded yet. ASR will not work until the model is installed.";
                    [alert addButtonWithTitle:@"Save Anyway"];
                    [alert addButtonWithTitle:@"Cancel"];
                    alert.alertStyle = NSAlertStyleWarning;
                    if ([alert runModal] != NSAlertFirstButtonReturn) {
                        return;
                    }
                }
            }
        }
    }

    NSString *dir = configDirPath();

    // Ensure directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSArray<NSDictionary *> *serializedTemplates = nil;
    if (self.templatesData) {
        [self saveCurrentTemplateEdits];
        NSString *templateError = nil;
        if (![self validateTemplatesDataWithMessage:&templateError]) {
            [self showAlert:@"Invalid prompt templates"
                       info:templateError ?: @"Check your templates and try again."];
            return;
        }
        serializedTemplates = [self serializedTemplatesData];
    }

    NSString *configPath = configFilePath();
    BOOL configExisted = [[NSFileManager defaultManager] fileExistsAtPath:configPath];
    NSString *originalConfigSnapshot = [NSString stringWithContentsOfFile:configPath
                                                                 encoding:NSUTF8StringEncoding
                                                                    error:nil] ?: @"";
    __block BOOL shouldRollbackConfig = NO;
    void (^rollbackConfigIfNeeded)(void) = ^{
        if (!shouldRollbackConfig) return;

        NSError *rollbackError = nil;
        if (!restoreConfigSnapshot(originalConfigSnapshot, configExisted, &rollbackError)) {
            NSLog(@"[Koe] Failed to restore config snapshot: %@", rollbackError.localizedDescription);
        }
        [self.rustBridge reloadConfig];
    };

    // Track whether any config write fails
    shouldRollbackConfig = YES;
    BOOL saveOk = YES;

    // Update ASR fields (always save — fields may be nil if pane not visited, check first)
    if (self.asrAppKeyField) {
        NSString *selectedProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubaoime";
        saveOk &= configSet(@"asr.provider", selectedProvider);
        // Save Doubao fields
        saveOk &= configSet(@"asr.doubao.app_key", self.asrAppKeyField.stringValue);
        NSString *accessKey = self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue;
        saveOk &= configSet(@"asr.doubao.access_key", accessKey);
        // Save Qwen fields
        NSString *qwenApiKey = self.asrQwenApiKeyToggle.tag == 1 ? self.asrQwenApiKeyField.stringValue : self.asrQwenApiKeySecureField.stringValue;
        saveOk &= configSet(@"asr.qwen.api_key", qwenApiKey);
        // Save Apple Speech locale
        if ([selectedProvider isEqualToString:@"apple-speech"]) {
            NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
            saveOk &= configSet(@"asr.apple-speech.locale", locale);
        }
        // Save local model selection
        if ([selectedProvider isEqualToString:@"mlx"]) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) saveOk &= configSet(@"asr.mlx.model", modelPath);
        } else if ([selectedProvider isEqualToString:@"sherpa-onnx"]) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) saveOk &= configSet(@"asr.sherpa-onnx.model", modelPath);
        }
    }

    // Update LLM fields
    if (self.llmEnabledCheckbox) {
        NSString *enabledStr = (self.llmEnabledCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        saveOk &= configSet(@"llm.enabled", enabledStr);

        [self syncActiveLlmProfileFromFields];
        NSDictionary *payload = @{
            @"active_profile": self.activeLlmProfileId ?: @"openai",
            @"profiles": self.llmProfiles ?: @{},
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
        if (!json || sp_llm_save_profiles_json(json.UTF8String) != 0) {
            saveOk = NO;
        }
    }

    // Update hotkey
    if (self.hotkeyPopup) {
        NSString *selectedTriggerHotkey = normalizedHotkeyValue(self.hotkeyPopup.selectedItem.representedObject ?: @"fn");
        saveOk &= configSet(@"hotkey.trigger_key", selectedTriggerHotkey);

        // Save trigger mode
        NSString *triggerModeValue = [self.triggerModePopup selectedItem].representedObject ?: @"hold";
        saveOk &= configSet(@"hotkey.trigger_mode", triggerModeValue);
    }
    if (self.overlayFontSizeSlider) {
        NSString *fontFamily = [self selectedOverlayFontFamilyValue];
        NSInteger fontSize = clampedOverlayFontSizeValue(lround(self.overlayFontSizeSlider.doubleValue));
        NSInteger bottomMargin = clampedOverlayBottomMarginValue(lround(self.overlayBottomMarginSlider.doubleValue));
        BOOL limitVisibleLines = self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
        NSInteger maxVisibleLines = [self selectedOverlayMaxVisibleLinesValue];
        saveOk &= configSet(@"overlay.font_family", fontFamily);
        saveOk &= configSet(@"overlay.font_size", [NSString stringWithFormat:@"%ld", (long)fontSize]);
        saveOk &= configSet(@"overlay.bottom_margin", [NSString stringWithFormat:@"%ld", (long)bottomMargin]);
        saveOk &= configSet(@"overlay.limit_visible_lines", limitVisibleLines ? @"true" : @"false");
        saveOk &= configSet(@"overlay.max_visible_lines", [NSString stringWithFormat:@"%ld", (long)maxVisibleLines]);
    }
    if (self.startSoundCheckbox) {
        NSString *startSound = (self.startSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *stopSound = (self.stopSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *errorSound = (self.errorSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        saveOk &= configSet(@"feedback.start_sound", startSound);
        saveOk &= configSet(@"feedback.stop_sound", stopSound);
        saveOk &= configSet(@"feedback.error_sound", errorSound);
    }
    if (self.templatesEnabledSwitch) {
        NSString *templatesEnabled = (self.templatesEnabledSwitch.state == NSControlStateValueOn) ? @"true" : @"false";
        saveOk &= configSet(@"llm.prompt_templates_enabled", templatesEnabled);
    }

    if (!saveOk) {
        rollbackConfigIfNeeded();
        [self showAlert:@"Some settings failed to save"
                   info:@"Check that ~/.koe/config.yaml is writable and try again."];
        return;
    }

    // Save prompt templates
    if (serializedTemplates) {
        if (![self.rustBridge setPromptTemplates:serializedTemplates]) {
            rollbackConfigIfNeeded();
            [self showAlert:@"Failed to save prompt templates"
                       info:@"Check your prompt templates and ~/.koe/config.yaml, then try again."];
            return;
        }
    }

    // Write dictionary.txt
    NSError *error = nil;
    if (self.dictionaryTextView) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        [self.dictionaryTextView.string writeToFile:dictPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write dictionary.txt: %@", error.localizedDescription);
            rollbackConfigIfNeeded();
            [self showAlert:@"Failed to save dictionary.txt" info:error.localizedDescription];
            return;
        }
    }

    // Write system_prompt.txt
    if (self.systemPromptTextView) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        [self.systemPromptTextView.string writeToFile:promptPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write system_prompt.txt: %@", error.localizedDescription);
            rollbackConfigIfNeeded();
            [self showAlert:@"Failed to save system_prompt.txt" info:error.localizedDescription];
            return;
        }
    }

    shouldRollbackConfig = NO;
    NSLog(@"[Koe] Settings saved");

    // Notify delegate to reload
    if ([self.delegate respondsToSelector:@selector(setupWizardDidSaveConfig)]) {
        [self.delegate setupWizardDidSaveConfig];
    }

    // Close the settings window on successful save so the user gets clear
    // feedback that the action completed. (Previously the click looked like
    // a no-op.)
    [self hideRuntimeOverlayPreview];
    [self.window close];
}

- (void)cancelSetup:(id)sender {
    [self endHotkeyRecording];
    [self hideRuntimeOverlayPreview];
    [self.window close];
}

- (void)llmEnabledToggled:(id)sender {
    [self updateLlmFieldsEnabled];
}

- (void)toggleLlmRemoteModelPicker:(id)sender {
    self.llmRemoteModelPickerExpanded = !self.llmRemoteModelPickerExpanded;
    if (self.llmRemoteModelPickerExpanded) {
        [self updateLlmFieldsEnabled];
        [self refreshLlmRemoteModels:nil];
    } else {
        [self updateLlmFieldsEnabled];
    }
}

- (void)setLlmRemoteModelPickerRowVisible:(BOOL)visible {
    if (_llmRemoteModelPickerRowVisible == visible) {
        return;
    }
    _llmRemoteModelPickerRowVisible = visible;

    // Keep the model picker row height in sync with layout built in buildLlmPane.
    CGFloat pickerRowHeight = 36.0; // rowH (32) + extra gap (4)
    CGFloat deltaY = visible ? -pickerRowHeight : pickerRowHeight;

    // Move all OpenAI controls below the model picker row (tags 2005-2008).
    for (NSView *view in self.currentPaneView.subviews) {
        if (view.tag >= 2005 && view.tag <= 2008) {
            NSRect frame = view.frame;
            frame.origin.y += deltaY;
            view.frame = frame;
        }
    }
}

- (void)populateLlmRemoteModelPopupWithModels:(NSArray<NSString *> *)models selectedModel:(NSString *)selectedModel {
    [self.llmRemoteModelPopup removeAllItems];

    if (models.count == 0) {
        [self.llmRemoteModelPopup addItemWithTitle:@"No models available"];
        self.llmRemoteModelPopup.lastItem.representedObject = nil;
        self.llmRemoteModelPopup.enabled = NO;
        return;
    }

    for (NSString *modelId in models) {
        [self.llmRemoteModelPopup addItemWithTitle:modelId];
        self.llmRemoteModelPopup.lastItem.representedObject = modelId;
    }

    if (selectedModel.length > 0) {
        for (NSInteger i = 0; i < self.llmRemoteModelPopup.numberOfItems; i++) {
            if ([[self.llmRemoteModelPopup itemAtIndex:i].representedObject isEqualToString:selectedModel]) {
                [self.llmRemoteModelPopup selectItemAtIndex:i];
                break;
            }
        }
    }
    self.llmRemoteModelPopup.enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);
}

- (void)llmRemoteModelChanged:(id)sender {
    NSString *model = self.llmRemoteModelPopup.selectedItem.representedObject;
    if (model.length > 0) {
        self.llmModelField.stringValue = model;
        [self syncActiveLlmProfileFromFields];
        self.llmTestResultLabel.stringValue = @"";
    }
}

- (void)refreshLlmRemoteModels:(id)sender {
    NSDictionary *activeProfile = [self activeLlmProfile];
    NSString *provider = [activeProfile[@"provider"] isKindOfClass:[NSString class]] ? activeProfile[@"provider"] : @"openai";
    BOOL isOpenAiLike = [provider isEqualToString:@"openai"] || [provider isEqualToString:@"apfel"];
    if (!isOpenAiLike) return;
    [self updateLlmFieldsEnabled];

    NSString *baseURL = [self.llmBaseUrlField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *apiKey = self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue;
    NSString *currentModel = [self.llmModelField.stringValue copy] ?: @"";
    if (baseURL.length == 0) {
        [self.llmRemoteModelPopup removeAllItems];
        [self.llmRemoteModelPopup addItemWithTitle:@"Enter Base URL first"];
        self.llmRemoteModelPopup.enabled = NO;
        return;
    }

    [self.llmRemoteModelPopup removeAllItems];
    [self.llmRemoteModelPopup addItemWithTitle:@"Loading models..."];
    self.llmRemoteModelPopup.enabled = NO;
    self.llmRefreshModelsButton.enabled = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSDictionary *result = [strongSelf.rustBridge llmRemoteModelsForBaseURL:baseURL apiKey:apiKey];
        BOOL success = [result[@"success"] boolValue];
        NSArray *modelsRaw = [result[@"models"] isKindOfClass:[NSArray class]] ? result[@"models"] : @[];
        NSMutableArray<NSString *> *models = [NSMutableArray arrayWithCapacity:modelsRaw.count];
        for (id item in modelsRaw) {
            if ([item isKindOfClass:[NSString class]] && [item length] > 0) {
                [models addObject:item];
            }
        }
        NSString *message = [result[@"message"] isKindOfClass:[NSString class]] ? result[@"message"] : @"";

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            NSDictionary *innerActive = [innerSelf activeLlmProfile];
            NSString *activeProvider = [innerActive[@"provider"] isKindOfClass:[NSString class]] ? innerActive[@"provider"] : @"openai";
            BOOL stillOpenAiLike = [activeProvider isEqualToString:@"openai"] || [activeProvider isEqualToString:@"apfel"];
            if (!stillOpenAiLike) return;

            innerSelf.llmRefreshModelsButton.enabled = (innerSelf.llmEnabledCheckbox.state == NSControlStateValueOn);
            if (success) {
                [innerSelf populateLlmRemoteModelPopupWithModels:models selectedModel:currentModel];
            } else {
                [innerSelf.llmRemoteModelPopup removeAllItems];
                [innerSelf.llmRemoteModelPopup addItemWithTitle:@"Load failed"];
                innerSelf.llmRemoteModelPopup.enabled = NO;
                if (message.length > 0) {
                    innerSelf.llmTestResultLabel.stringValue = [NSString stringWithFormat:@"Model list: %@", message];
                    innerSelf.llmTestResultLabel.textColor = [NSColor systemOrangeColor];
                }
            }
        });
    });
}

- (void)updateLlmFieldsEnabled {
    BOOL enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);
    self.llmProfileTableView.enabled = enabled;
    self.llmAddProfileButton.enabled = enabled;
    self.llmDeleteProfileButton.enabled = enabled && self.llmProfiles.count > 1;
    self.llmProfileNameField.enabled = enabled;

    NSDictionary *activeProfile = [self activeLlmProfile];
    NSString *provider = [activeProfile[@"provider"] isKindOfClass:[NSString class]] ? activeProfile[@"provider"] : @"openai";
    // APFEL is just an OpenAI-compatible endpoint with a distinct label, so it
    // reuses the same field set as "openai".
    BOOL isOpenAiLike = [provider isEqualToString:@"openai"] || [provider isEqualToString:@"apfel"];
    BOOL isMlx = [provider isEqualToString:@"mlx"];

    // Toggle OpenAI fields (tag 2001-2008). Tag 2004 (Model List row) is
    // managed separately below because its visibility is gated by the
    // expand/collapse state of the Choose button.
    [self setHidden:!isOpenAiLike
 forViewsWithTagInRange:NSMakeRange(2001, 8)
             inView:self.currentPaneView];
    // Eye toggle doesn't use tag for show/hide (tag is used for 0/1 state)
    self.llmApiKeyToggle.hidden = !isOpenAiLike;
    // Preserve API key visibility state when showing OpenAI fields
    if (isOpenAiLike) {
        BOOL showPlain = (self.llmApiKeyToggle.tag == 1);
        self.llmApiKeyField.hidden = !showPlain;
        self.llmApiKeySecureField.hidden = showPlain;
    }

    self.llmBaseUrlField.enabled = enabled;
    self.llmApiKeyField.enabled = enabled;
    self.llmApiKeySecureField.enabled = enabled;
    self.llmModelField.enabled = enabled;
    self.llmToggleModelPickerButton.hidden = !isOpenAiLike;
    self.llmToggleModelPickerButton.enabled = enabled && isOpenAiLike;
    [self.llmToggleModelPickerButton setTitle:(self.llmRemoteModelPickerExpanded ? @"Hide" : @"Choose")];
    BOOL showRemoteModelPicker = isOpenAiLike && self.llmRemoteModelPickerExpanded;
    [self setLlmRemoteModelPickerRowVisible:showRemoteModelPicker];
    [self setHidden:!showRemoteModelPicker
 forViewsWithTagInRange:NSMakeRange(2004, 1)
             inView:self.currentPaneView];
    BOOL hasSelectableRemoteModel = (self.llmRemoteModelPopup.selectedItem.representedObject != nil);
    self.llmRemoteModelPopup.enabled = enabled && showRemoteModelPicker && hasSelectableRemoteModel;
    self.llmRefreshModelsButton.enabled = enabled && showRemoteModelPicker;
    self.llmChatCompletionsPathField.enabled = enabled;
    self.maxTokenParamPopup.enabled = enabled;
    self.llmTestButton.enabled = enabled;

    // Toggle MLX fields (tag 2010-2012)
    [self setHidden:!isMlx
 forViewsWithTagInRange:NSMakeRange(2010, 3)
             inView:self.currentPaneView];
    if (isMlx) {
        self.llmLocalModelPopup.enabled = enabled;
        self.llmModelDownloadButton.enabled = enabled;
        self.llmModelDeleteButton.enabled = enabled;
        // Progress bar stays hidden unless downloading
        self.llmModelProgressBar.hidden = YES;
        self.llmModelProgressSizeLabel.hidden = YES;
    }
}

- (void)populateLlmLocalModelPopup {
    [self.llmLocalModelPopup removeAllItems];

    NSArray<NSDictionary *> *models = [self.rustBridge scanModels];
    for (NSDictionary *model in models) {
        if (![model[@"provider"] isEqualToString:@"mlx"]) continue;
        NSString *modelMode = model[@"mode"];
        if (!modelMode || modelMode.length == 0) modelMode = @"asr";
        if (![modelMode isEqualToString:@"llm"]) continue;

        NSString *path = model[@"path"];
        NSString *title = model[@"description"] ?: path;

        [self.llmLocalModelPopup addItemWithTitle:title];
        [self.llmLocalModelPopup lastItem].representedObject = path;
    }

    if (self.llmLocalModelPopup.numberOfItems == 0) {
        [self.llmLocalModelPopup addItemWithTitle:@"No models found"];
        self.llmLocalModelPopup.enabled = NO;
    } else {
        self.llmLocalModelPopup.enabled = YES;
    }
}

- (void)llmLocalModelChanged:(id)sender {
    [self updateLlmModelStatusLabel];
}

- (void)updateLlmModelStatusLabel {
    NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
    if (!modelPath) {
        self.llmModelStatusLabel.stringValue = @"";
        self.llmModelDownloadButton.enabled = NO;
        self.llmModelDeleteButton.enabled = NO;
        self.llmModelProgressBar.hidden = YES;
        self.llmModelProgressSizeLabel.hidden = YES;
        return;
    }

    if ([self.downloadingModels containsObject:modelPath]) {
        self.llmModelStatusLabel.stringValue = @"Downloading";
        self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.llmModelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                         accessibilityDescription:@"Stop"];
        self.llmModelDownloadButton.enabled = YES;
        self.llmModelDeleteButton.enabled = NO;
        self.llmModelProgressBar.hidden = NO;
        self.llmModelProgressSizeLabel.hidden = NO;
        return;
    }

    NSInteger cachedStatus = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyCacheOnly];
    if (cachedStatus == 2) {
        [self applyLlmModelStatus:cachedStatus];
        return;
    }

    [self applyLlmModelStatus:(cachedStatus > 0 ? cachedStatus : 1) verifying:YES];

    dispatch_async(_verifyQueue, ^{
        NSInteger verified = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyNormal];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *current = self.llmLocalModelPopup.selectedItem.representedObject;
            if ([current isEqualToString:modelPath]) {
                [self applyLlmModelStatus:verified];
            }
        });
    });
}

- (void)applyLlmModelStatus:(NSInteger)status {
    [self applyLlmModelStatus:status verifying:NO];
}

- (void)applyLlmModelStatus:(NSInteger)status verifying:(BOOL)verifying {
    self.llmModelProgressBar.hidden = YES;
    self.llmModelProgressSizeLabel.hidden = YES;
    self.llmModelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                     accessibilityDescription:@"Download"];
    switch (status) {
        case 2:
            self.llmModelStatusLabel.stringValue = verifying ? @"● Verifying…" : @"● Installed";
            self.llmModelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemGreenColor];
            self.llmModelDownloadButton.enabled = NO;
            self.llmModelDeleteButton.enabled = YES;
            break;
        case 1:
            self.llmModelStatusLabel.stringValue = verifying ? @"◐ Verifying…" : @"◐ Incomplete";
            self.llmModelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemOrangeColor];
            self.llmModelDownloadButton.enabled = YES;
            self.llmModelDeleteButton.enabled = YES;
            break;
        default:
            self.llmModelStatusLabel.stringValue = @"○ Not installed";
            self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
            self.llmModelDownloadButton.enabled = YES;
            self.llmModelDeleteButton.enabled = NO;
            break;
    }
}

- (void)llmDownloadSelectedModel:(id)sender {
    NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    if ([self.downloadingModels containsObject:modelPath]) {
        [self.rustBridge cancelDownload:modelPath];
        return;
    }

    if (!self.downloadingModels) {
        self.downloadingModels = [NSMutableSet new];
    }
    [self.downloadingModels addObject:modelPath];

    self.llmModelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                     accessibilityDescription:@"Stop"];
    self.llmModelDownloadButton.hidden = NO;
    self.llmModelStatusLabel.stringValue = @"Downloading...";
    self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.llmModelProgressBar.hidden = NO;
    self.llmModelProgressBar.doubleValue = 0;
    self.llmModelProgressSizeLabel.hidden = NO;
    self.llmModelProgressSizeLabel.stringValue = @"";

    __block uint64_t totalBytesAllFiles = 0;
    for (NSDictionary *m in [self.rustBridge scanModels]) {
        if ([m[@"path"] isEqualToString:modelPath]) {
            totalBytesAllFiles = [m[@"total_size"] unsignedLongLongValue];
            break;
        }
    }
    __block NSMutableDictionary<NSNumber *, NSNumber *> *fileDownloaded = [NSMutableDictionary new];

    __weak typeof(self) weakSelf = self;
    [self.rustBridge downloadModel:modelPath
        progress:^(NSUInteger fileIndex, NSUInteger fileCount,
                   uint64_t downloaded, uint64_t total, NSString *filename) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            NSString *selected = strongSelf.llmLocalModelPopup.selectedItem.representedObject;
            if (![modelPath isEqualToString:selected]) return;

            fileDownloaded[@(fileIndex)] = @(downloaded);

            uint64_t totalDownloaded = 0;
            for (NSNumber *v in fileDownloaded.allValues) totalDownloaded += v.unsignedLongLongValue;

            double pct = (totalBytesAllFiles > 0)
                ? (double)totalDownloaded / (double)totalBytesAllFiles * 100.0 : 0;
            strongSelf.llmModelProgressBar.doubleValue = pct;
            strongSelf.llmModelStatusLabel.stringValue = @"Downloading";
            strongSelf.llmModelProgressSizeLabel.stringValue =
                [NSString stringWithFormat:@"%.1f / %.1f MB",
                    (double)totalDownloaded / 1048576.0,
                    (double)totalBytesAllFiles / 1048576.0];
        }
        completion:^(BOOL success, NSString *message) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.downloadingModels removeObject:modelPath];
            [strongSelf updateLlmModelStatusLabel];
        }];
}

- (void)llmDeleteSelectedModel:(id)sender {
    NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove Model Files?";
    alert.informativeText = @"Downloaded model files will be deleted. The model can be re-downloaded later.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.rustBridge removeModelFiles:modelPath];
        [self updateLlmModelStatusLabel];
    }
}

- (void)testLlmConnection:(id)sender {
    NSDictionary *profile = [self runtimeLlmProfileForActiveProfile];
    if (!profile) {
        self.llmTestResultLabel.stringValue = @"Please select an LLM profile first.";
        self.llmTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]] ? profile[@"provider"] : @"openai";
    NSString *baseUrl = [profile[@"base_url"] isKindOfClass:[NSString class]] ? profile[@"base_url"] : @"";
    NSString *model = [profile[@"model"] isKindOfClass:[NSString class]] ? profile[@"model"] : @"";
    if ([provider isEqualToString:@"openai"] && (baseUrl.length == 0 || model.length == 0)) {
        self.llmTestResultLabel.stringValue = @"Please fill in Base URL and Model first.";
        self.llmTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profile options:0 error:nil];
    NSString *profileJson = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
    if (profileJson.length == 0) {
        self.llmTestResultLabel.stringValue = @"Test failed: invalid profile data";
        self.llmTestResultLabel.textColor = [NSColor systemRedColor];
        return;
    }

    self.llmTestButton.enabled = NO;
    self.llmTestResultLabel.stringValue = @"Testing...";
    self.llmTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Run the Rust-side test on a background thread; the profile path matches runtime correction.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *raw = sp_llm_test_profile_json(profileJson.UTF8String);
        NSString *jsonStr = raw ? [NSString stringWithUTF8String:raw] : @"";
        if (raw) sp_core_free_string(raw);

        NSDictionary *result = nil;
        if (jsonStr.length > 0) {
            result = [NSJSONSerialization JSONObjectWithData:
                [jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.llmTestButton.enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);

            if (!result) {
                self.llmTestResultLabel.stringValue = @"Test failed: invalid response from core";
                self.llmTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            BOOL success = [result[@"success"] boolValue];
            NSString *message = result[@"message"] ?: @"Unknown result";
            NSNumber *elapsedMs = result[@"elapsed_ms"];
            NSString *timeStr = elapsedMs
                ? [NSString stringWithFormat:@" (%.1fs)", elapsedMs.doubleValue / 1000.0] : @"";

            self.llmTestResultLabel.stringValue =
                [NSString stringWithFormat:@"%@%@", message, timeStr];
            self.llmTestResultLabel.textColor = success
                ? [NSColor systemGreenColor] : [NSColor systemRedColor];
        });
    });
}

// ─── ASR Test Connection ────────────────────────────────────────────

- (void)testAsrConnection:(id)sender {
    NSString *provider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubaoime";
    if ([provider isEqualToString:@"doubaoime"]) {
        [self testDoubaoImeConnection];
    } else if ([provider isEqualToString:@"doubao"]) {
        [self testDoubaoConnection];
    } else if ([provider isEqualToString:@"qwen"]) {
        [self testQwenConnection];
    }
}

- (void)testDoubaoImeConnection {
    self.asrTestButton.enabled = NO;
    self.asrTestResultLabel.stringValue = @"Testing...";
    self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Test by connecting to the DoubaoIME WebSocket endpoint
    NSURL *url = [NSURL URLWithString:@"wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=401734&device_id=0"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 5;
    [request setValue:@"com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"v2" forHTTPHeaderField:@"proto-version"];
    [request setValue:@"true" forHTTPHeaderField:@"x-custom-keepalive"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionWebSocketTask *wsTask = [session webSocketTaskWithRequest:request];

    __weak typeof(self) weakSelf = self;
    [wsTask resume];

    // If WebSocket connects successfully, the endpoint is reachable
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // If the task is still running after 2s, it means the connection was established
        if (wsTask.state == NSURLSessionTaskStateRunning) {
            [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            strongSelf.asrTestButton.enabled = YES;
            strongSelf.asrTestResultLabel.stringValue = @"Connected (device registration will complete on first use)";
            strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
        } else if (wsTask.state == NSURLSessionTaskStateCompleted) {
            strongSelf.asrTestButton.enabled = YES;
            if (wsTask.error) {
                strongSelf.asrTestResultLabel.stringValue = [NSString stringWithFormat:@"Connection failed: %@", wsTask.error.localizedDescription];
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
            } else {
                strongSelf.asrTestResultLabel.stringValue = @"Connected (device registration will complete on first use)";
                strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
            }
        }
    });
}

- (void)testDoubaoConnection {
    // Get current key values (account for plain/secure toggle state)
    NSString *appKey = self.asrAppKeyField.stringValue;
    NSString *accessKey = self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue;

    NSDictionary<NSString *, NSString *> *customHeaders = asrCustomHeaders(@"doubao");

    if (customHeaders == nil && (appKey.length == 0 || accessKey.length == 0)) {
        self.asrTestResultLabel.stringValue = @"Please fill in App Key and Access Key first";
        self.asrTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.asrTestButton.enabled = NO;
    self.asrTestResultLabel.stringValue = @"Testing...";
    self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Create WebSocket connection test
    NSString *doubaoUrl = configGet(@"asr.doubao.url");
    if (doubaoUrl.length == 0) doubaoUrl = @"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
    NSURL *url = [NSURL URLWithString:doubaoUrl];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 5;

    if (customHeaders) {
        // Runtime fully replaces default auth headers when asr.doubao.headers is set.
        for (NSString *headerName in customHeaders) {
            [request setValue:customHeaders[headerName] forHTTPHeaderField:headerName];
        }
    } else {
        // Set Doubao auth headers
        [request setValue:appKey forHTTPHeaderField:@"X-Api-App-Key"];
        [request setValue:accessKey forHTTPHeaderField:@"X-Api-Access-Key"];
        [request setValue:@"volc.seedasr.sauc.duration" forHTTPHeaderField:@"X-Api-Resource-Id"];
        [request setValue:[[NSUUID UUID] UUIDString] forHTTPHeaderField:@"X-Api-Connect-Id"];
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionWebSocketTask *wsTask = [session webSocketTaskWithRequest:request];

    __weak typeof(self) weakSelf = self;
    __block BOOL hasCompleted = NO;

    // Try to receive a message (Doubao may not send one immediately)
    [wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasCompleted) return;
            hasCompleted = YES;

            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            strongSelf.asrTestButton.enabled = YES;

            if (error) {
                NSString *errorMsg = error.localizedDescription;

                // Check userInfo for HTTP status code
                NSHTTPURLResponse *response = error.userInfo[@"NSURLSessionDownloadTaskResumeData"];
                NSInteger statusCode = 0;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    statusCode = response.statusCode;
                }

                if ([errorMsg containsString:@"401"] || [errorMsg containsString:@"403"] ||
                    [error.localizedFailureReason containsString:@"401"] || statusCode == 401) {
                    strongSelf.asrTestResultLabel.stringValue = @"Auth failed: please check App Key and Access Key";
                } else if ([errorMsg containsString:@"time"] || error.code == NSURLErrorTimedOut) {
                    strongSelf.asrTestResultLabel.stringValue = @"Connection timed out: please check your network";
                } else if ([errorMsg containsString:@"bad response"] ||
                           [errorMsg containsString:@"Bad response"] ||
                           statusCode == 400 || statusCode == 403) {
                    // HTTP error during WebSocket handshake (e.g. 400 Bad Request)
                    strongSelf.asrTestResultLabel.stringValue = @"Auth failed: please check App Key and Access Key";
                } else if ([errorMsg containsString:@"unable"] ||
                           [errorMsg containsString:@"Unable"] ||
                           [errorMsg containsString:@"Cannot connect"] ||
                           [errorMsg containsString:@"Network"]) {
                    strongSelf.asrTestResultLabel.stringValue = @"Network error: please check your network settings";
                } else {
                    strongSelf.asrTestResultLabel.stringValue = @"Connection failed: please check your configuration";
                }
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            strongSelf.asrTestResultLabel.stringValue = @"Connected";
            strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
        });
    }];

    [wsTask resume];

    // Doubao may not send a message immediately; treat no error within 2s as success
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (hasCompleted) return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

        if (!strongSelf.asrTestButton.enabled) {
            strongSelf.asrTestButton.enabled = YES;
            strongSelf.asrTestResultLabel.stringValue = @"Connected";
            strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
        }
    });

    // Fallback timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (hasCompleted) return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue = @"Connection timed out: please check your network";
        strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
    });
}

- (void)testQwenConnection {
    // Get current key value (account for plain/secure toggle state)
    NSString *apiKey = self.asrQwenApiKeyToggle.tag == 1 ? self.asrQwenApiKeyField.stringValue : self.asrQwenApiKeySecureField.stringValue;

    NSDictionary<NSString *, NSString *> *customHeaders = asrCustomHeaders(@"qwen");

    if (customHeaders == nil && apiKey.length == 0) {
        self.asrTestResultLabel.stringValue = @"Please fill in API Key first";
        self.asrTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.asrTestButton.enabled = NO;
    self.asrTestResultLabel.stringValue = @"Testing...";
    self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Create WebSocket connection test
    NSString *qwenBaseUrl = configGet(@"asr.qwen.url");
    if (qwenBaseUrl.length == 0) qwenBaseUrl = @"wss://dashscope.aliyuncs.com/api-ws/v1/realtime";
    NSString *qwenModel = configGet(@"asr.qwen.model");
    if (qwenModel.length == 0) qwenModel = @"qwen3-asr-flash-realtime";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?model=%@", qwenBaseUrl, qwenModel]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;

    if (customHeaders) {
        // Runtime fully replaces the Authorization header when asr.qwen.headers is set.
        for (NSString *headerName in customHeaders) {
            [request setValue:customHeaders[headerName] forHTTPHeaderField:headerName];
        }
    } else {
        // Set Qwen DashScope auth header
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionConfiguration *config2 = [NSURLSessionConfiguration defaultSessionConfiguration];
    config2.timeoutIntervalForRequest = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config2];
    NSURLSessionWebSocketTask *wsTask = [session webSocketTaskWithRequest:request];

    __weak typeof(self) weakSelf = self;
    __weak NSURLSessionWebSocketTask *weakWsTask = wsTask;

    // Qwen DashScope returns a session.created message on connect
    [wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            [weakWsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

            strongSelf.asrTestButton.enabled = YES;

            if (error) {
                NSString *errorMsg = error.localizedDescription;
                NSInteger statusCode = 0;

                // Try to extract HTTP status code from error
                if (error.userInfo[@"_kCFStreamErrorDomainKey"]) {
                    NSNumber *code = error.userInfo[@"_kCFStreamErrorDomainKey"];
                    if (code) statusCode = code.integerValue;
                }

                if ([errorMsg containsString:@"401"] || [errorMsg containsString:@"403"] ||
                    statusCode == 401) {
                    strongSelf.asrTestResultLabel.stringValue = @"Auth failed: please check your API Key";
                } else if ([errorMsg containsString:@"time"] || error.code == NSURLErrorTimedOut) {
                    strongSelf.asrTestResultLabel.stringValue = @"Connection timed out: please check your network";
                } else if ([errorMsg containsString:@"bad response"] ||
                           [errorMsg containsString:@"Bad response"]) {
                    // HTTP error during WebSocket handshake
                    strongSelf.asrTestResultLabel.stringValue = @"Auth failed: please check your API Key";
                } else if ([errorMsg containsString:@"unable"] ||
                           [errorMsg containsString:@"Unable"] ||
                           [errorMsg containsString:@"Cannot connect"]) {
                    strongSelf.asrTestResultLabel.stringValue = @"Network error: please check your network settings";
                } else {
                    strongSelf.asrTestResultLabel.stringValue = @"Connection failed: please check your configuration";
                }
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            if (message) {
                strongSelf.asrTestResultLabel.stringValue = @"Connected";
                strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
            } else {
                strongSelf.asrTestResultLabel.stringValue = @"Connection failed: no response from server";
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
            }
        });
    }];

    [wsTask resume];

    // Timeout handler
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.asrTestButton.enabled) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue = @"Connection timed out: please check your network";
        strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
    });
}

- (void)showAlert:(NSString *)message info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end
